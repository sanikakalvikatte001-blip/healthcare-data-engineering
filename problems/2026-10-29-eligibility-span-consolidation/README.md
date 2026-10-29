# Eligibility Span Consolidation and HEDIS Continuous Enrollment

Turn messy member eligibility segments (from 834 enrollment files) into clean coverage spans, find coverage gaps, and decide which members meet HEDIS continuous enrollment rules.

## Problem

Health plans receive member eligibility as many small segments, not clean spans. For one member you often see:

- monthly segments that are really one continuous coverage period
- overlapping segments from retro adds and re-sent files
- exact duplicates when the same 834 file is loaded twice
- bad rows where the term date is before the effective date
- open-ended coverage stored with the high date `9999-12-31`

Before you can answer "was this member covered all year?", these segments must be merged into true coverage spans.

## Why it matters

- **HEDIS / quality reporting:** Almost every HEDIS measure needs continuous enrollment, usually *no more than one gap of up to 45 days* in the measurement year, *plus enrollment on the anchor date* (Dec 31). Wrong spans mean wrong denominators and wrong Star ratings.
- **Member months and PMPM:** Finance metrics count covered days. Overlaps double-count; splits under-count.
- **Claims:** Claims are checked against coverage on the date of service. A false gap can deny a valid claim.
- **Warehouse design:** A clean span table is the base for the member eligibility dimension.

## Approach

```
834 segments ──► clean ──► consolidate (gaps & islands) ──► gaps ──► continuous enrollment check
                 │                  │                                       │
       drop term<eff,        running max of term_date,              clip to measurement year,
       exact duplicates      new island when eff > max+1            count gaps at start/middle/end,
                                                                    check anchor date
```

1. **Clean** — remove rows where `term_date < eff_date` and exact duplicate date ranges.
2. **Consolidate** — classic *gaps and islands*. Sort by member, plan, effective date. Track the **running max** of term date seen so far. A new span starts only when the effective date is more than 1 day after that max. Dates are inclusive, so `term 01-31` and `eff 02-01` merge.
   - *Key detail:* a running max (not `LAG`) is required. If one long segment covers several short ones, `LAG` on the previous row would split the span by mistake. There is a test for this.
3. **Gaps** — list each break between spans with start date, end date, and length in days.
4. **Continuous enrollment** — clip spans to the measurement year (2025), count uncovered days at the start, middle, and end as gaps, then apply the rule: ≤ 1 gap, gap ≤ 45 days, enrolled on 12/31. Each member gets a `reason` so failures are easy to explain to quality teams.
5. **SQL version** — the same consolidation is written in SQL ([`consolidate_spans.sql`](src/consolidate_spans.sql)) with window functions, the way it would run in a warehouse. The pipeline and the tests check that Python and SQL produce **identical** spans.

Other choices:
- Dates are parsed at second precision so `9999-12-31` works in pandas (nanosecond timestamps stop at year 2262 — a common bug with eligibility data).
- Spans are built per **member + plan**, because continuous enrollment is checked within a product line.

## How to run

```bash
pip install -r requirements.txt
python src/generate_data.py     # writes data/eligibility_segments.csv (synthetic)
python src/run_pipeline.py      # writes output/*.csv and prints a summary
python -m pytest tests -q       # 18 tests
```

## Results

Synthetic data: 500 members, 1,286 segments, 11 real-world scenarios.

| Step | Result |
|---|---|
| Invalid rows removed (term < eff) | 38 |
| Duplicate rows removed | 57 |
| Clean segments → coverage spans | 1,191 → 664 (**44.2% fewer rows**) |
| Coverage gaps found | 164 |
| Python and SQL spans match | ✅ True |

**HEDIS continuous enrollment, MY2025:** 323 of 500 members (64.6%) are eligible.

| Reason | Members |
|---|---|
| pass | 323 |
| gap_too_long (> 45 days) | 74 |
| not_enrolled_on_anchor_date | 59 |
| too_many_gaps (> 1) | 44 |

Each scenario lands where it should: monthly segments, overlaps, duplicates, and bad rows all still pass after cleaning; members with a short gap (≤ 45 days) pass; long gaps, two gaps, and early terms fail with the right reason.

Output files:
- `output/coverage_spans.csv` — one row per continuous coverage span
- `output/coverage_gaps.csv` — one row per gap
- `output/continuous_enrollment_2025.csv` — pass/fail and reason per member

## Project structure

```
├── data/eligibility_segments.csv   # synthetic 834-style segments
├── output/                         # spans, gaps, continuous enrollment results
├── src/
│   ├── generate_data.py            # synthetic data with realistic messy cases
│   ├── spans.py                    # clean, consolidate, gaps, continuous enrollment
│   ├── consolidate_spans.sql       # same consolidation in SQL (DuckDB)
│   └── run_pipeline.py             # runs everything, checks SQL == Python
└── tests/test_spans.py             # 18 pytest tests
```

*All data is synthetic. No PHI.*
