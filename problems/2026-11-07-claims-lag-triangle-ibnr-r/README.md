# Claims lag triangles, completion factors & IBNR (R, tidyverse)

Turn a paid-claims extract into **service-date → paid-date lag triangles**, develop **chain-ladder completion factors** per claim type, estimate **IBNR** (incurred but not reported) for open months, and publish a **reporting gate** that tells downstream jobs which incurred months are complete enough to trust.

## Problem

A claims warehouse is organised by *paid* date — that's when the 837/835 data arrives. But almost every business question is about *incurred* (service) date: PMPM cost trend, utilization per 1,000, HEDIS admin-data refreshes, value-based contract settlements. At any point in time the latest incurred months are only partly paid:

- Professional claims (837P) mostly pay within a month or two.
- Facility claims (837I) take much longer — inpatient stays, coordination of benefits, pended reviews.
- A small share of claims pay 6–18 months late (resubmissions, appeals), and reversals/replacements change amounts after the fact.

If a dashboard sums paid amounts by service month, the last quarter always looks like costs are falling. That "drop" is just claims that haven't arrived yet.

## Why it matters

- **Finance / actuarial**: IBNR is a balance-sheet liability for payers and risk-bearing provider groups (MA, ACO REACH, capitated contracts).
- **Reporting**: PMPM and utilization dashboards need either completed estimates or a clear "not final yet" marker.
- **Quality / HEDIS**: admin-data refreshes should wait for enough run-out; this gives a measured cut-off instead of a guess.
- **Data engineering**: the same pipeline catches feed defects (re-sent lines, paid-before-service, missing dates) before they leak into the triangle.

## Approach

```
paid_claims_extract.csv
   │
   ├─ dedupe_claim_lines()      re-sent claim_line_ids collapse; reversals (freq 8) and
   │                            replacements (freq 7) stay and NET against the original
   ├─ validate_claims()         rule list → one reason code per rejected row → exception table
   │
   └─ per segment (claim_type), nested tibble + purrr::map:
        build_triangle()        incurred month × lag month, zero-filled, cumulative paid;
                                months with nothing paid yet still get a row
        age_to_age_factors()    volume-weighted, most recent 12 incurred months per lag
        completion_factors()    CDF = product of remaining factors, CF = 1 / CDF
        project_ultimate()      chain ladder; Bornhuetter-Ferguson below 50% complete;
                                reportable = CF ≥ 95%
```

Key decisions:

| Decision | Why |
|---|---|
| Separate triangles for Professional vs Institutional | Payment patterns are very different; one blended curve is wrong for both. |
| Volume-weighted factors over a 12-month window | Big months count more; a recent window follows changes in payer turnaround times. |
| Bornhuetter-Ferguson for months < 50% complete | Chain ladder multiplies a tiny paid amount by a huge factor (284× for facility lag 0). BF blends paid-to-date with an expected ultimate from the last 6 reportable months. |
| Fold payments beyond `max_dev_lag` into the last bucket | Keeps the triangle bounded without dropping dollars. |
| All settings in `config.yml` | Valuation date, window, gate, BF threshold and segment column change without code edits. |

Code style: small pure functions in `R/`, pipe-friendly tidyverse, a config-driven CLI (`run_pipeline.R`) and an R Markdown walkthrough (`analysis/`) that renders to GitHub markdown.

## Project layout

```
config.yml                     run settings
R/validate.R                   intake rules, dedupe, exception split
R/chain_ladder.R               triangle, age-to-age, completion factors, IBNR / BF
R/pipeline.R                   config loader, per-segment orchestration, backtest, writers
run_pipeline.R                 CLI entry point → output/*.csv
data-raw/generate_claims.R     synthetic data generator (seeded)
data/                          generated extract + synthetic "true ultimate"
analysis/claims_lag_walkthrough.Rmd / .md   notebook-style walkthrough with chart
tests/testthat/                unit tests on hand-calculated toy triangle + end-to-end tests
output/                        triangle, factors, IBNR, exceptions, backtest
```

## How to run

Requires R ≥ 4.1 and the packages in `DESCRIPTION` (`install.packages(c("dplyr","tidyr","purrr","readr","lubridate","tibble","yaml","testthat","rmarkdown","knitr","ggplot2","scales"))`; the walkthrough also needs pandoc).

```bash
cd problems/2026-11-07-claims-lag-triangle-ibnr-r

Rscript data-raw/generate_claims.R        # synthetic extract (seeded, reproducible)
Rscript run_pipeline.R                    # writes output/*.csv and prints a summary
Rscript tests/testthat.R                  # 39 expectations
Rscript -e 'rmarkdown::render("analysis/claims_lag_walkthrough.Rmd")'
```

## Synthetic data

`generate_claims.R` simulates the **full run-out** of claim lines incurred Jan 2024 – Jun 2026 (≈240 professional and ≈90 facility lines a month, with winter seasonality), gamma-shaped payment lags plus a 4% long tail (4–18 months), and 3% reversals of which 70% get a replacement at a different amount. It saves the true ultimate per month (only knowable because the data is synthetic), then cuts the data at the 2026-06-30 valuation date and injects feed defects: 40 re-sent lines, 12 paid-before-service lines, 8 lines missing a service date. No real PHI.

## Results

Valuation date 2026-06-30.

**Intake**

| Stage | Rows |
|---|---:|
| Raw extract | 9,875 |
| After dedupe (40 re-sends removed) | 9,835 |
| Exceptions (8 missing service date, 12 paid before service) | 20 |
| Clean lines in triangle | 9,815 |

**Payment lag** (original lines)

| Claim type | Lines | Median lag (days) | P90 lag (days) | Paid ≤ 30 days | Paid ≤ 90 days |
|---|---:|---:|---:|---:|---:|
| Professional | 6,971 | 34 | 69 | 42.2% | 95.4% |
| Institutional | 2,395 | 76 | 155 | 4.7% | 62.2% |

**Completion factors** — professional months reach the 95% gate at lag 3; facility months need lag 7.

| Lag (months) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Professional | 12.0% | 66.1% | 90.9% | 95.5% | 96.6% | 96.8% | 97.0% | 97.3% |
| Institutional | 0.4% | 17.1% | 48.8% | 70.7% | 84.5% | 90.4% | 93.6% | 96.2% |

**Open months (2026)** — total IBNR **$822,569** on $7.91M paid to date. Reportable today: Professional Jan–Mar 2026; Institutional through Nov 2025.

| Claim type | Incurred | Paid to date | Completion | Method | Est. ultimate | IBNR |
|---|---|---:|---:|---|---:|---:|
| Professional | 2026-03 | 43,408 | 95.5% | chain ladder | 45,465 | 2,058 |
| Professional | 2026-05 | 27,008 | 66.1% | chain ladder | 40,870 | 13,862 |
| Professional | 2026-06 | 4,126 | 12.0% | BF | 46,712 | 42,586 |
| Institutional | 2026-03 | 178,390 | 70.7% | chain ladder | 252,272 | 73,881 |
| Institutional | 2026-05 | 24,336 | 17.1% | BF | 219,920 | 195,584 |
| Institutional | 2026-06 | 0 | 0.4% | BF | 234,971 | 234,971 |

**Backtest vs synthetic truth** — mean absolute error of the month's total:

| Claim type | Maturity | Months | Paid-to-date only | Projected |
|---|---|---:|---:|---:|
| Institutional | 0–2 months | 3 | 83.3% | 22.1% |
| Institutional | 3–5 months | 3 | 21.2% | 6.2% |
| Institutional | 6+ months | 24 | 1.4% | 0.8% |
| Professional | 0–2 months | 3 | 46.2% | 10.0% |
| Professional | 3–5 months | 3 | 5.7% | 2.4% |
| Professional | 6+ months | 24 | 0.6% | 0.3% |

Reading the numbers: reporting raw paid amounts for the latest quarter would understate facility cost by 21–83%. The projection cuts that error by roughly 2–5× and the gate tells you which months are still estimates. The newest months stay uncertain (±20%) because this synthetic book is small — around 90 facility lines a month — which is exactly the case where BF is safer than pure chain ladder.

Full walkthrough with the triangle and completion chart: [`analysis/claims_lag_walkthrough.md`](analysis/claims_lag_walkthrough.md).

## Possible extensions

- Tail factor (curve fit past lag 24) and confidence ranges (Mack / bootstrap).
- PMPM-based expected ultimate for BF using an eligibility table.
- Write completion factors back to the warehouse as a `dim_completion_factor` table keyed by segment + lag + valuation date.
