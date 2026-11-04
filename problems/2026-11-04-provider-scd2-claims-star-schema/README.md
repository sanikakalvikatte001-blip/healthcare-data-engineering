# Provider SCD Type 2 dimension + claims star schema (point-in-time attribution)

**Tech:** SQL (DuckDB 1.5, CLI only), layered staging → intermediate → mart models, SQL data tests
**Area:** Warehouse modeling / Claims / Provider network

## Problem

Payers and provider groups receive a **monthly provider roster** (credentialing / network file). Between files a provider can:

- go **in → out of network** (or out and back in a few months later),
- change **specialty / taxonomy** (e.g. finishes a fellowship),
- move to a new **group TIN** after an acquisition,
- **drop off** the roster (termed), or appear mid-year (late credentialing).

The files are also messy: name casing and padding change from month to month, rows are duplicated, a month gets **re-delivered** with corrections, and a provider is sometimes just **missing from one file**.

Claims, meanwhile, come in with **replacements (freq 7)**, **voids (freq 8)** and **duplicate re-sends**.

If the warehouse keeps only the current provider row (Type 1) or builds Type 2 history the naive way, claims get reported under the network status, specialty and TIN the provider has *today*, not the ones that applied on the **date of service**.

## Why it matters

- **Network leakage / OON spend** reports, which drive contracting decisions, come out wrong.
- **Specialty-level cost and utilization** shifts history into the wrong specialty.
- **TIN-level** value-based contract settlements, which are paid per group, credit the wrong group.
- Quality measure **attribution** (HEDIS/MIPS) depends on the provider's status during the measurement period.

## Approach

```
seeds/      generate_synthetic_sources.sql   raw.* (roster snapshots, members, claim lines)
models/
  staging/       stg_provider_roster   trim/upper, latest re-delivery wins, dedupe, attr_hash
                 stg_claim_lines       typing + drop byte-identical re-sends
                 stg_members
  intermediate/  int_provider_monthly_state  dense provider x month grid: gap carry-forward, TERMED
                 int_provider_versions       gaps-and-islands -> SCD2 versions
                 int_claim_lines_current     latest version per line, voids removed
  marts/         dim_date, dim_member (Type 1), dim_provider (Type 2)
                 fct_claim_line              point-in-time provider key on DOS
                 mart_network_paid_monthly   IN / OUT / TERMED / NOT_ON_ROSTER paid by month
                 mart_attribution_drift      what a "join to current row" report gets wrong
tests/      assert_*.sql + run_tests.sql     SQL data tests (rows returned = failures)
build.sql   runs everything in dependency order with .read
```

Key design decisions:

| Decision | Why |
|---|---|
| **Gaps-and-islands** (`lag` change flag + running `sum`) instead of `GROUP BY` attributes | `GROUP BY` merges IN → OUT → IN into one IN row that spans the OUT months. The negative test below shows this. |
| `attr_hash` over the **Type 2 columns only** (taxonomy, network, TIN, roster status); name is **Type 1** | A name casing fix should not split a provider's history. |
| **Latest `load_ts` wins** per `snapshot_date` | A re-delivered August file replaces the first one instead of creating a one-month false OUT version. |
| **Dense month grid** | A provider missing from one file and back the next month is treated as a feed gap, so the previous attributes are carried forward. A provider missing from every later file gets a **TERMED** version starting from the first missing file. |
| Inferred **PRE_ROSTER** version (1900-01-01 → day before first file) for late-credentialed providers | Claims with a DOS before credentialing still get a point-in-time key and are not counted as in-network. |
| `provider_sk = -1` Unknown member | Claims with NPIs that are on no roster stay in the fact table, so paid totals still reconcile. |
| Hash surrogate keys `md5(npi\|effective_from)` | Keys stay the same when a rebuild adds new providers. |
| Inclusive `effective_to` (next start − 1 day) with `9999-12-31` for open versions | Lets BI tools use a simple `BETWEEN` join. Tests check that versions are contiguous. |

## How to run

```bash
pip install -r requirements.txt     # installs the DuckDB CLI (duckdb-cli==1.5.6)
make all                            # build + test
# or without make:
duckdb -bail warehouse.duckdb < build.sql
duckdb -bail warehouse.duckdb < tests/run_tests.sql
```

`run_tests.sql` exits non-zero through DuckDB's `error()` if any test returns rows.

## Results

The synthetic sources have 754 roster rows (12 monthly files and 1 re-delivery) for 60 providers, and 5,208 raw claim lines (originals, 192 replacement lines, 120 void lines, 96 duplicate re-sends).

**Reconciliation:** 5,208 raw lines → 5,112 after removing duplicates → 4,800 unique claim lines → **4,680 fact lines** (120 voided). Fact paid is **$639,016.00** and matches the latest non-void versions in raw exactly.

**dim_provider:** 95 rows. That is 60 providers plus the Unknown member: 31 providers with 1 version, 25 with 2, 3 with 3, and 1 with 4 (IN → OUT → IN → TERMED). The A-B-A network flip for one provider comes out as three versions:

| version_no | network_status | specialty_desc | group_tin  | roster_status | effective_from | effective_to | is_current |
|-----------:|----------------|----------------|------------|---------------|----------------|--------------|------------|
| 1          | IN             | Psychiatry     | 84-1001111 | ACTIVE        | 2025-01-01     | 2025-04-30   | false      |
| 2          | OUT            | Psychiatry     | 84-1001111 | ACTIVE        | 2025-05-01     | 2025-06-30   | false      |
| 3          | IN             | Psychiatry     | 84-1001111 | ACTIVE        | 2025-07-01     | 9999-12-31   | true       |

**How fact lines got their provider key:**

| provider_match_type | claim_lines | paid_amt  |
|---------------------|------------:|----------:|
| POINT_IN_TIME       | 4281        | 584683.40 |
| PRE_ROSTER          | 179         | 24477.20  |
| UNKNOWN_NPI         | 152         | 21009.80  |
| TERMED              | 68          | 8845.60   |

**Attribution drift (point-in-time vs. join to current row):** 834 of 4,528 known-provider lines (18%) would be reported with the wrong network, specialty or TIN. For network status alone this is **540 lines / $73,002.20**. In-network paid is **$469,398.80** at DOS but would show as $453,438.80 if joined to the current row.

| attribute      | at DOS → current                                     | claim_lines | paid_amt |
|----------------|------------------------------------------------------|------------:|---------:|
| group_tin      | 84-1003333 -> 84-9990000                             | 55          | 8012.80  |
| group_tin      | 84-1000000 -> 84-9990000                             | 54          | 7410.40  |
| network_status | IN -> OUT                                            | 171         | 23357.60 |
| network_status | NOT_ON_ROSTER -> IN                                  | 107         | 14720.40 |
| network_status | IN -> TERMED                                         | 81          | 11161.00 |
| network_status | OUT -> TERMED                                        | 76          | 10168.20 |
| network_status | NOT_ON_ROSTER -> OUT                                 | 72          | 9756.80  |
| network_status | OUT -> IN                                            | 33          | 3838.20  |
| specialty      | Dermatology -> Interventional Cardiology             | 41          | 5884.40  |
| specialty      | Obstetrics & Gynecology -> Interventional Cardiology | 38          | 5317.60  |
| specialty      | Internal Medicine -> Interventional Cardiology       | 35          | 5173.40  |
| specialty      | Orthopaedic Surgery -> Interventional Cardiology     | 38          | 4769.00  |
| specialty      | Cardiovascular Disease -> Interventional Cardiology  | 33          | 4019.40  |

Two sample months from `mart_network_paid_monthly`. The TERMED bucket shows up after providers drop off the roster in October:

| service_month | network_status_at_dos | claim_lines | claims | paid_amt | pct_of_month_paid |
|---------------|-----------------------|------------:|-------:|---------:|------------------:|
| 2025-06       | IN                    | 275         | 136    | 38022.60 | 71.4              |
| 2025-06       | OUT                   | 102         | 48     | 12980.60 | 24.4              |
| 2025-06       | UNKNOWN               | 15          | 7      | 2263.00  | 4.2               |
| 2025-12       | IN                    | 283         | 142    | 38544.00 | 72.8              |
| 2025-12       | OUT                   | 70          | 36     | 9294.40  | 17.6              |
| 2025-12       | TERMED                | 24          | 12     | 3339.00  | 6.3               |
| 2025-12       | UNKNOWN               | 15          | 8      | 1777.20  | 3.4               |

**Tests:** all 8 SQL data test suites pass:

- one current row per NPI
- contiguous, non-overlapping versions
- no redundant versions
- unique surrogate keys
- fact grain with no fan-out
- point-in-time key validity
- raw → fact row and dollar reconciliation
- 8 business scenarios planted in the seed

**Negative check:** replacing the gaps-and-islands step with a naive `dense_rank()` over the attribute hash (the same as grouping by attributes) makes 4 of the 8 suites fail (399 failing rows): versions overlap, the point-in-time join fans out to 383 duplicate lines, reconciliation breaks, and the A-B-A scenario fails. So the tests catch the bug this model is built to avoid.

Exported marts are in `output/`. All data is synthetic, and the NPIs are made-up 10-digit numbers.
