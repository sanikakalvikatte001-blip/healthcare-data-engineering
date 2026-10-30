# 837P Claim-Line Load Reconciliation (Staging → Warehouse)

A config-driven reconciliation and data quality framework in PostgreSQL. It proves that an 837P professional claims batch landed in the warehouse completely and correctly, and it writes every problem to an exception table that a data steward can work.

## Problem

Claims ETL jobs usually finish "green" while the data is wrong. After an 837P batch is parsed into staging and loaded into the claim-line fact, these are common:

- **Missing lines:** rows dropped by a filter or a failed cast, with nothing logged
- **Duplicate lines:** a job restarted mid-batch without delete/insert, so lines load twice
- **Extra lines:** rows from another file stamped with this batch id
- **Wrong values:** allowed amount mapped into billed, a UTC timestamp that shifts the service date by one day, a modifier dropped by a fixed-width mapping
- **Bad source content:** NPIs with broken check digits, ICD-10 codes with decimals, service dates after the file arrived, zero units, invalid place of service, blank member ids

The usual check, "source row count = target row count," misses most of these. In this batch the line counts **tie out exactly (5,000 = 5,000)** while 27 lines are wrong.

## Why it matters

- **Finance:** Billed and paid totals in the warehouse feed IBNR, accruals and provider reports. A $328 variance in one small batch becomes real money across a year of files.
- **Quality and risk adjustment:** Missing or duplicated lines change HEDIS numerators and HCC capture. A shifted service date can move a visit outside a measurement period.
- **Audit:** Payers and auditors ask, "How do you know this file loaded completely?" A stored run history with control totals and row-level exceptions is the answer.
- **Operations:** A steward needs the exact claim and column that is wrong, not a failed job.

## Approach

```
src.stg_837p_claim_line (all TEXT, as parsed from X12)
        │
        │  recon.v_expected_line  (trim, upper, cast — the same rules the load uses)
        ▼
dw.fact_claim_line (typed)  ◄── dw.load_fact_claim_line(batch)   idempotent delete + insert
        │
        ▼
recon.run_reconciliation(batch) ──► recon.run_log        one row per run, PASS / WARN / FAIL
                                ├─► recon.control_total  source vs target, batch + service-month grain
                                ├─► recon.rule_result    one row per rule per run
                                └─► recon.exception      one row per bad line, with JSON detail
```

**1. Normalize before you compare.** Staging stores `' 99213 '`, `'gt'`, `'125.5'` and `'20260801'`. The warehouse stores `99213`, `GT`, `125.50` and a `date`. Both sides go through the same normalization and one hash function, `util.claim_line_hash(...)`, with explicit number formats and a NULL marker (`~`) so `NULL` and `''` hash differently. A raw-text comparison of the same data reports **4,993 false mismatches**. The normalized comparison reports **13**, and all 13 are real.

**2. Control totals at two grains.** Line count, claim count, billed amount and units, for the whole batch and by service month. The month grain shows *where* a variance lives. For example, the three extra lines show up as a June 2026 month that has no source rows at all.

**3. Row-level reconciliation on the business key** `(claim_id, line_no)`:

| Rule | How it works |
|---|---|
| `RECON_MISSING_IN_TARGET` | `NOT EXISTS` from expected to actual |
| `RECON_EXTRA_IN_TARGET` | `NOT EXISTS` from actual to expected |
| `RECON_DUPLICATE_IN_TARGET` | `row_number()` over the key; one exception per surplus copy |
| `RECON_VALUE_MISMATCH` | hash compare against the first copy only (so duplicates are not double-counted). The detail lists the exact columns that differ, plus both hashes |

**4. Source data quality rules** (WARN: the line still loads, but it is flagged): NPI Luhn check (CMS algorithm with the `80840` prefix), ICD-10-CM shape for X12 (no decimal point), service date after received date, billed ≤ 0, units ≤ 0, place of service not in the reference list, blank member id.

**5. Config-driven.** Every check is a row in `recon.rule_catalog` with a severity, a tolerance (`max_exceptions`) and its SQL. A `{batch_id}` placeholder is filled in at run time. Adding a check is an `INSERT`, not a code change. The runner executes each rule in its own exception block, so one broken rule is logged as `FAIL (-1)` and does not stop the run.

**6. Run status.** `FAIL` if any CRITICAL rule is over its tolerance. `WARN` if any WARN rule is over its tolerance. Otherwise `PASS`. `DQ_BILLED_NONPOSITIVE` allows up to 5 rows (no-charge lines are legitimate), so 3 rows still pass.

Style note: set-based SQL for every check, and procedural PL/pgSQL only for the runner (dynamic SQL, error isolation, status roll-up).

## Files

| File | Purpose |
|---|---|
| `sql/00_schema.sql` | `src`, `dw`, `util`, `recon` schemas and tables |
| `sql/01_functions.sql` | NPI Luhn, normalization + hash, expected/actual views, load procedure |
| `sql/02_generate_synthetic_source.sql` | 2,000 synthetic claims / 5,000 lines + 21 source DQ defects (deterministic) |
| `sql/03_load_with_defects.sql` | Runs the real load, then simulates 27 load bugs |
| `sql/04_rule_catalog.sql` | 11 rules (4 RECON, 7 SOURCE_DQ) |
| `sql/05_run_reconciliation.sql` | `recon.run_reconciliation(batch_id)` |
| `sql/06_report.sql` | Report for the latest run |
| `tests/test_reconciliation.sql` | 9 SQL tests (`DO` blocks with `ASSERT`) |

## How to run

Needs PostgreSQL 14+ and `psql` (tested on PostgreSQL 16.15). Connection settings come from the standard `PG*` environment variables. Use `docker compose up -d` for a throwaway database.

```bash
export PGDATABASE=claims_recon          # plus PGHOST/PGUSER/PGPASSWORD if needed
./run.sh                                # build, generate, load, reconcile, print report
./tests/run_tests.sh                    # rebuild from scratch + run the 9 tests
```

## Results

Synthetic batch `B20261030`: 2,000 claims, 5,000 service lines, dates of service from July to October 2026. Run status: **FAIL** (as intended: 27 load defects were planted).

**Batch control totals**

| Metric | Source | Target | Variance |
|---|---:|---:|---:|
| line_count | 5,000 | 5,000 | **0** |
| claim_count | 2,000 | 2,001 | +1 |
| billed_amount | 703,184.12 | 702,856.34 | −327.78 |
| units | 10,018 | 10,014 | −4 |

Line count ties out because −7 missing + 4 duplicate + 3 extra = 0. Only the row-level checks catch the problem.

**Rule results**: every planted defect was found, with no false positives.

| Rule | Severity | Exceptions | Tolerance | Status |
|---|---|---:|---:|---|
| RECON_MISSING_IN_TARGET | CRITICAL | 7 | 0 | FAIL |
| RECON_DUPLICATE_IN_TARGET | CRITICAL | 4 | 0 | FAIL |
| RECON_EXTRA_IN_TARGET | CRITICAL | 3 | 0 | FAIL |
| RECON_VALUE_MISMATCH | CRITICAL | 13 | 0 | FAIL |
| DQ_NPI_LUHN | WARN | 6 | 0 | WARN |
| DQ_ICD10_FORMAT | WARN | 5 | 0 | WARN |
| DQ_BILLED_NONPOSITIVE | WARN | 3 | 5 | PASS |
| DQ_FUTURE_DOS | WARN | 2 | 0 | WARN |
| DQ_UNITS_ZERO | WARN | 2 | 0 | WARN |
| DQ_POS_INVALID | WARN | 2 | 0 | WARN |
| DQ_MEMBER_ID_MISSING | WARN | 1 | 0 | WARN |

**Value mismatches by column:** billed_amount 6, service_from_date 4, modifier_1 4. One line (`CLM0000351`) has two wrong columns and is reported once, with both columns listed.

**Normalization check:** naive raw-text comparison = 4,993 mismatches. Normalized hash = 13.

**After a clean reload** (test T08): 0 RECON exceptions, all control totals tie out, the 21 source DQ warnings remain, and the run status is **WARN**.

**Tests:** 9 of 9 pass. They cover the NPI Luhn check against the CMS example `1234567893`, hash normalization, exact counts and keys for every planted defect, mismatch column detail, control totals and month roll-up, tolerance, broken-rule isolation, idempotent reload, and run-history consistency.
