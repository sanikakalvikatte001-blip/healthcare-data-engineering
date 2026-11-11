# HEDIS Controlling High Blood Pressure (CBP): a layered DuckDB warehouse that combines EHR vitals and CPT II claims

**Area:** Quality measures (HEDIS) / Clinical + claims data integration / Warehouse modeling
**Tech:** SQL (DuckDB 1.5), layered models (raw → staging → intermediate → marts), SCD Type 2, window functions, gaps-and-islands, SQL data tests

## Problem

A health plan has to report **Controlling High Blood Pressure (CBP)**: the share of members aged 18–85 with hypertension whose most recent blood pressure in the measurement year is below 140/90. The measure needs data from three feeds that don't agree with each other:

| Feed | What goes wrong in real life |
|---|---|
| **Eligibility (834-style segments)** | The same segment is resent in later files, sometimes with a corrupt field. Members switch product line mid-year (Medicaid → Medicare at 65). Gaps in coverage decide whether a member counts at all. |
| **Professional claims** | HTN diagnoses come with or without dots and in mixed case. The same visit is billed twice on the same day. Some BP results arrive only as **CPT II band codes** (3074F/3075F/3077F, 3078F/3079F/3080F), not as numbers. Exclusions (hospice, ESRD, pregnancy, frailty + advanced illness) are spread across claim lines. |
| **EHR vitals** | BP comes as free text (`"138 / 88 mmHg"`), as separate systolic/diastolic columns, or as junk (`0/0`, `Pt refused`, swapped `78/136`). Readings from the **ED or an inpatient stay do not count**. When a member has several readings on the same day, HEDIS uses the **lowest systolic and the lowest diastolic**, even if they come from different readings. |

Each of these rules is simple on its own. Together they produce a measure rate that is easy to get wrong without noticing.

## Why it matters

- CBP is a **triple-weighted** Medicare Star Rating measure and appears in Medicaid and commercial (QRS) quality programs, so a few points of rate change real money and plan ratings.
- Common bugs push the rate in opposite directions. Counting ED readings makes members look *uncontrolled*. Using the highest reading of the day instead of the lowest does the same. Double-counting resent eligibility segments makes members look *non-continuously enrolled*. These errors don't cancel out. They just make the number wrong.
- Care-management teams need a **gap list** they can act on (who has no reading, who is uncontrolled, and who their PCP is), not only a percentage.

## Approach

Each layer has its own folder, and each model is its own `.sql` file. `pipeline.sql` runs them in dependency order with the DuckDB CLI. No Python is involved.

```
reference/                      value sets, CPT II bands, measure parameters, expected scenarios (CSV)
warehouse/
├── 00_raw/                     landing tables (all VARCHAR) + synthetic feeds
│   ├── 01_scenario_members.sql     22 hand-built edge cases (S01–S22)
│   └── 02_synthetic_population.sql 2,000 hash-seeded members (deterministic)
├── 10_staging/                 typing, normalization, dedup, BP text parsing + validation
├── 20_intermediate/            business rules
│   ├── int_enrollment_my           gaps-and-islands → continuous enrollment
│   ├── int_htn_visits              ≥2 distinct HTN visit dates in the window
│   ├── int_exclusion_event         per-category look-back windows
│   ├── int_bp_candidates           EHR readings ∪ CPT II band → value
│   └── int_representative_bp       latest date, same-day MIN(sys), MIN(dia)
└── 30_marts/                   star schema + measure outputs
    ├── dim_member                  SCD2 on (product_line, pcp_npi)
    ├── dim_date
    ├── fct_bp_reading              point-in-time member_sk, + dq_bp_reject
    ├── fct_cbp_member              one row per member: flags + single outcome
    ├── mart_cbp_rate               GROUPING SETS by product line + ALL
    └── mart_cbp_care_gap           outreach worklist with priority
tests/                          23 SQL data tests, single runner
```

Key design decisions:

1. **Parameters are data.** `reference/measure_params.csv` holds the measurement year, age band, HTN window, CE gap rules, thresholds and frailty ages. `ref.cbp_params` derives every date window from it, so no model hard-codes a date. To run next year, change one value.
2. **Value sets are data.** Codes are stored without dots and upper-cased. Claims are unpivoted (`stg.claim_code`) into one row per code so that every rule becomes a single equality join. *(The value sets here are a small illustrative subset, not the licensed NCQA value sets. The HTN window and exclusion look-backs are simplified from the published spec.)*
3. **Continuous enrollment with gaps-and-islands.** Segments are clipped to the measurement year and merged with a running `max(seg_end)` window (overlapping and adjacent segments merge). Leading, interior and trailing gaps are measured separately. A member passes CE when they are enrolled on Dec 31 and have at most one gap of 45 days or less.
4. **The HEDIS representative-BP rule in one window.** Readings are aggregated per member and date (`min(systolic)`, `min(diastolic)`, and both must be present). Then `QUALIFY row_number() … ORDER BY reading_date DESC = 1` picks the latest date. ED and inpatient readings (EHR setting or claim POS 21/23) are flagged `counts_for_cbp = false`, not deleted.
5. **CPT II bands become representative values** (3075F → 139, 3077F → 140, 3079F → 89, …). Banded claims then flow through the same min/latest logic as EHR numbers, and the band edges still classify correctly against `< 140 / < 90`.
6. **SCD2 member dimension with point-in-time keys.** A new version starts only when product line or PCP changes. An enrollment gap alone does not create a version. `fct_bp_reading` joins on `reading_date BETWEEN valid_from AND valid_to`. Readings taken *before* the member's first coverage (the EHR knew the patient before they joined the plan) map to version 1 and are flagged `BEFORE_FIRST_VERSION`. The first test run caught this case as 11 orphaned facts. The measure reports members under their **Dec 31** product line.
7. **One outcome per member.** Each member gets exactly one outcome, assigned in a fixed order: `NOT_ELIGIBLE_AGE` → `NOT_ELIGIBLE_ENROLLMENT` → `NOT_IN_DENOMINATOR_HTN` → `EXCL_*` → `NUMERATOR` / `GAP_UNCONTROLLED` / `GAP_NO_READING`. The funnel therefore always adds up, and an analyst can explain any single member.
8. **Bad data is quarantined, not dropped.** Unparseable, out-of-range and swapped BP rows go to `mart.dq_bp_reject` with a reason. The tests reconcile raw = loaded + rejected.

## How to run

```bash
pip install -r requirements.txt        # DuckDB CLI (duckdb-cli==1.5.6)
make all                               # build + test
# or without make (from this folder):
duckdb -bail cbp.duckdb < pipeline.sql
duckdb -bail cbp.duckdb < tests/run_tests.sql   # non-zero exit if any test fails
```

The build takes about a second. It writes `output/cbp_rate.csv`, `cbp_outcomes.csv`, `cbp_care_gaps.csv` and `dq_bp_rejects.csv`.

**Tests (23, all passing)** fall into four groups:
- **Golden scenarios:** each of S01–S22 must land on the outcome and Dec 31 product line in `reference/expected_scenarios.csv`. Seven of them also check the exact representative BP value.
- **Measure logic:** numerator ⊆ denominator ⊆ eligible population. Numerator members are strictly < 140/90. The ALL row equals the sum of the product lines. Gap list = denominator − numerator.
- **BP rules, re-derived independently:** the latest countable date, the same-day minimums, never ED/inpatient.
- **Dimension and reconciliation:** unique surrogate key, one current row, contiguous versions, no redundant versions, point-in-time keys, resend dedup, raw vitals = facts + rejects, CPT II claims = CPT II facts.

As a negative check, raising `systolic_threshold` to 150 makes 2 tests fail: 3 scenario outcomes and 74 numerator members.

## Results

Simulated full measurement year 2026: 2,022 members with coverage in the year, 6,091 claim lines and 2,197 EHR vital rows.

**CBP rate by product line**

| Product line | Eligible pop. | Required exclusions | Denominator | Numerator | Gap: uncontrolled | Gap: no reading | Rate |
|---|---:|---:|---:|---:|---:|---:|---:|
| COMMERCIAL | 178 | 11 | 167 | 87 | 54 | 26 | 52.10% |
| MEDICAID | 174 | 13 | 161 | 76 | 57 | 28 | 47.20% |
| MEDICARE | 179 | 18 | 161 | 89 | 57 | 15 | 55.28% |
| **ALL** | **531** | **42** | **489** | **252** | **168** | **69** | **51.53%** |

**Member funnel (one outcome per member)**: 977 not in the denominator (fewer than 2 HTN visit dates), 379 outside the 18–85 age band, 135 failing continuous enrollment, 42 excluded (13 hospice, 12 ESRD, 7 frailty age 81+, 6 frailty + advanced illness, 4 pregnancy), and 252 numerator, 168 uncontrolled and 69 with no reading.

**Data quality and modeling**
- 89 EHR vital rows quarantined: 51 out of range (`0/0`), 19 swapped systolic/diastolic and 19 unparseable (`Pt refused`). Raw 2,197 = 2,108 loaded + 89 rejected.
- 2,404 raw coverage rows → 2,197 segments after collapsing resends.
- `dim_member`: 2,077 versions for 2,022 members (55 members have a PCP or product-line change).
- `fct_bp_reading`: 2,362 readings (2,108 EHR + 254 CPT II claims). 165 are ED readings excluded from the measure, and 11 are pre-enrollment readings mapped to version 1.
- Care-gap worklist: 237 members. **11 are priority 1** (representative BP ≥ 160 or ≥ 100), 69 are priority 2 (no BP this year) and 157 are priority 3.

**Edge cases**, all asserted by tests:

| Scenario | Data | Result |
|---|---|---|
| S02 | Two readings on the latest date: 150/92 and 144/86 | 144/86 → **uncontrolled** |
| S03 | Same day: 146/82 and 136/92 | MIN/MIN → 136/82 → **controlled** |
| S05 | Office 130/80, then ED 170/100 | ED ignored → **controlled** |
| S06 / S07 | CPT II only: 3075F+3079F / 3077F+3078F | 139/89 controlled / 140/79 uncontrolled |
| S11 vs S10 | Age 72 with frailty only vs frailty + Alzheimer's | evaluated vs **excluded** |
| S15 vs S16 | One 30-day gap vs one 61-day gap | CE passes vs fails |
| S18 | Medicaid → Medicare on Jul 1 | 2 SCD2 versions, reported under **MEDICARE** |
| S19 | `"138 / 88 mmHg"`, later `78/136` | text parsed, swapped row rejected → 138/88 |
| S21 | 140/89 | boundary → **uncontrolled** (must be < 140) |
| S22 | Same segment in 3 files, one with a corrupt PCP | latest file wins, no false gap |

All data is synthetic and generated by SQL (hash-seeded, so it is reproducible). No PHI.
