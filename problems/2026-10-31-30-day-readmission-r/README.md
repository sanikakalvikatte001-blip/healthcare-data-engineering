# 30-Day All-Cause Readmissions from Inpatient Claims (R, data.table)

## Problem

A payer analytics team needs a 30-day unplanned readmission rate, overall and by discharging hospital, from UB-04 inpatient facility claims. The raw claims make that harder than it looks:

- **Claim versions.** The same stay arrives as an original (frequency code 1), then replacements (7) or voids (8). If you count every row, you count admissions twice. If you keep a voided claim, you count a stay that never happened.
- **Direct transfers.** A patient moved from Hospital A to Hospital B produces two claims, but it is one episode of care. Without chaining, the transfer looks like a readmission on day 0.
- **Interim and overlapping bills.** These must be absorbed into one stay, not split it.
- **Denominator rules.** In-hospital deaths, transfers out, members under 18, maternity/perinatal stays, discharges too late in the year to have 30 days of follow-up, and members without 30 days of continuous enrollment after discharge are not eligible index stays.
- **Planned readmissions.** A scheduled return for chemotherapy, rehab or transplant follow-up does not count as a readmission.

## Why it matters

Readmission rates drive CMS HRRP penalties, value-based contract bonuses, HEDIS PCR reporting and care-management outreach lists. Getting the definition wrong in either direction has a cost. An inflated rate unfairly flags hospitals and wastes care-management effort. An undercount hides real quality problems. In this synthetic dataset, a naive raw-claim query flags **24.6%** of claim rows as readmitted. The correct rate is **14.6%**.

## Approach

The code is a small R package (`DESCRIPTION`, `R/`, `tests/testthat/`). It is written in a functional style: each step is a pure function that takes a `data.table` and returns a new one, so each step can be tested on its own.

| Step | Function | Key technique |
|------|----------|---------------|
| 1. Current claim version | `current_claim_versions()` | Newest `received_date` per `original_claim_id`; drop it if the newest version is a void |
| 2. Claims → stays | `build_stays()` | Gaps-and-islands with `cummax()` of prior discharge dates. A claim admitted ≤ 1 day after the running max discharge joins the same stay. Status and facility come from the closing claim. |
| 3. Index eligibility | `select_index_stays()` | `fcase()` waterfall where the first failing rule wins. Continuous enrollment uses merged 834-style spans and a **non-equi join** (`eff_date <= discharge`, `term_date >= discharge + 30`). |
| 4. Readmission flag | `flag_readmissions()` | Non-equi join of index stays to later stays admitted on days 1–30 after discharge. The first *unplanned*, non-maternity stay is the readmission. |
| 5. Rates | `readmission_rates()`, `index_waterfall()` | Observed rate overall and by discharging facility, plus a denominator waterfall |

Design decisions (simplified from HEDIS PCR / CMS HWR):

- A readmission does **not** have to be an eligible index stay itself. For example, a readmission where the member died still counts. A stay can also be both a readmission and its own index stay.
- The readmission is attributed to the **final** (discharging) facility of a transfer chain.
- The planned-readmission rule looks at the principal diagnosis on the readmission's admitting claim. The maternity exclusion applies if any claim in the chain carries an O / Z37 / Z38 / P code.
- All rule parameters (measurement period, transfer gap, status codes, diagnosis prefixes) are in `R/config.R`.

## How to run

```bash
# R >= 4.1 with data.table and testthat
#   Ubuntu: apt-get install -y r-base r-cran-data.table r-cran-testthat
#   or in R: install.packages(c("data.table", "testthat"))
cd problems/2026-10-31-30-day-readmission-r
Rscript scripts/generate_data.R     # synthetic members, enrollment, claim versions -> data/
Rscript scripts/run_pipeline.R      # prints reconciliation + rates, writes output/
Rscript tests/testthat.R            # unit tests on hand-built fixtures
```

## Results

Synthetic run: 600 members, measurement year 2025, `set.seed(20261031)`. Tested on R 4.3.3 with data.table 1.14.10.

**Claim → stay reconciliation**

| | Count |
|---|---:|
| Claim versions received | 733 |
| Original claims | 661 |
| Voided (dropped) | 13 |
| Current claims | 648 |
| Stays after transfer chaining | 604 (44 multi-claim) |

**Denominator waterfall**

| Step | Removed | Remaining |
|---|---:|---:|
| All stays | | 604 |
| Discharge outside Jan 1 – Dec 1 | 27 | 577 |
| Died during stay | 22 | 555 |
| Transferred out to acute care | 20 | 535 |
| Under 18 at discharge | 16 | 519 |
| Maternity / perinatal | 30 | 489 |
| Not enrolled 30 days post-discharge | 10 | 479 |
| **Eligible index stays** | | **479** |

**Readmission rate:** 70 unplanned readmissions out of 479 index stays = **14.6%**. The median time to readmission is 15.5 days. Another 25 index stays had only a planned return, and those are correctly not counted.

| Discharging facility (synthetic NPI) | Index stays | Readmissions | Rate % |
|---|---:|---:|---:|
| 1900050055 | 63 | 17 | 27.0 |
| 1900030033 | 106 | 20 | 18.9 |
| 1900020022 | 108 | 14 | 13.0 |
| 1900040044 | 65 | 8 | 12.3 |
| 1900010011 | 137 | 11 | 8.0 |

The facility ranking matches the readmission bias built into the generator: 26% > 20% > 16% > 12% > 10%. The 13.0% and 12.3% facilities swap places, which is expected sampling noise at about 65–110 stays each.

For comparison, the naive approach treats every claim row as a stay and any claim admitted 0–30 days later as a readmission. It flags 180 of 733 rows (24.6%), which overstates the rate by about 10 points.

**Tests:** 17 `test_that` blocks / 51 expectations, all passing. They cover replacements and voids, same-day and next-day transfers, nested interim bills, the day-30 vs day-31 boundary, birthday-aware age (including Feb 29), enrollment span merging, each exclusion reason, planned-then-unplanned sequences, death on readmission, readmission-as-index, and rate rollups.

Output files in `output/`: `stays.csv`, `index_stay_readmission_flags.csv`, `denominator_waterfall.csv`, `readmission_rate_by_facility.csv`.

*All data is synthetic and generated by `scripts/generate_data.R`. No PHI.*
