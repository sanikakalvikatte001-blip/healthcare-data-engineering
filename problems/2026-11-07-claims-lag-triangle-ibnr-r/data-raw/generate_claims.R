# Generate a synthetic paid-claims extract (no real PHI).
#
# How it works:
#   1. Simulate the FULL run-out of claim lines incurred Jan 2024 - Jun 2026
#      (service date -> paid date lag differs by claim type).
#   2. Add adjustments: ~3% of lines are reversed (frequency code 8, negative
#      amount) and some are replaced (frequency code 7) with a corrected amount.
#   3. Save the TRUE ultimate paid per incurred month - only knowable because
#      the data is synthetic - so the chain-ladder estimate can be checked.
#   4. Truncate at the valuation date (what the warehouse actually sees), then
#      inject typical feed defects: duplicate lines, paid-before-service,
#      missing service date.
#
# Run from the project folder:  Rscript data-raw/generate_claims.R

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
  library(readr)
})

set.seed(20261107)

valuation_date <- as.Date("2026-06-30")
incurred_months <- seq(as.Date("2024-01-01"), as.Date("2026-06-01"), by = "month")

# Claim-type profiles: volume per month, allowed-amount lognormal, lag (days)
profiles <- tibble::tribble(
  ~claim_type,     ~lines_per_month, ~amt_meanlog, ~amt_sdlog, ~lag_floor, ~lag_shape, ~lag_scale,
  "Professional",  240,              4.9,          0.8,         10,         2.0,        14,
  "Institutional",  90,              7.6,          0.8,         18,         2.2,        32
)

simulate_month <- function(month_start, p) {
  # Mild seasonality: winter months carry more utilization
  season <- 1 + 0.12 * cos(2 * pi * (month(month_start) - 1) / 12)
  n <- rpois(1, p$lines_per_month * season)
  dos <- month_start + sample(0:(days_in_month(month_start) - 1), n, replace = TRUE)

  # Most claims pay on a gamma-shaped lag; ~4% are resubmissions / appeals
  # that pay 4-18 months later (the "long tail" that bites IBNR).
  lag <- p$lag_floor + round(rgamma(n, shape = p$lag_shape, scale = p$lag_scale))
  long_tail <- runif(n) < 0.04
  lag[long_tail] <- sample(120:540, sum(long_tail), replace = TRUE)

  tibble(
    claim_type   = p$claim_type,
    service_date = dos,
    paid_date    = dos + lag,
    paid_amount  = round(rlnorm(n, p$amt_meanlog, p$amt_sdlog), 2)
  )
}

original <- purrr::map_dfr(seq_len(nrow(profiles)), function(i) {
  purrr::map_dfr(incurred_months, simulate_month, p = profiles[i, ])
}) |>
  mutate(
    claim_id       = sprintf("CLM%07d", row_number()),
    claim_line_id  = paste0(claim_id, "-01"),
    claim_freq_cd  = "1",                        # 1 = original
    lob            = sample(c("Commercial", "Medicare Advantage"), n(),
                            replace = TRUE, prob = c(0.65, 0.35))
  )

# --- Adjustments: reversal (freq 8) of the full amount, 70% get a replacement (freq 7)
adj_idx  <- sample(nrow(original), round(0.03 * nrow(original)))
adjusted <- original[adj_idx, ]

reversals <- adjusted |>
  mutate(
    paid_date     = paid_date + sample(20:90, n(), replace = TRUE),
    paid_amount   = -paid_amount,
    claim_freq_cd = "8",
    claim_line_id = paste0(claim_id, "-R1")
  )

replacements <- reversals |>
  filter(runif(n()) < 0.70) |>
  mutate(
    paid_date     = paid_date + sample(0:10, n(), replace = TRUE),
    paid_amount   = round(-paid_amount * runif(n(), 0.6, 1.1), 2),
    claim_freq_cd = "7",
    claim_line_id = paste0(claim_id, "-A1")
  )

full_runout <- bind_rows(original, reversals, replacements)

# --- Ground truth: ultimate net paid per incurred month and claim type
truth <- full_runout |>
  mutate(incurred_month = floor_date(service_date, "month")) |>
  group_by(claim_type, incurred_month) |>
  summarise(true_ultimate_paid = round(sum(paid_amount), 2), .groups = "drop")

# --- What the warehouse sees at the valuation date
extract <- full_runout |> filter(paid_date <= valuation_date)

# Feed defects ---------------------------------------------------------------
dupes <- extract |> slice_sample(n = 40)                       # resent lines

bad_dates <- extract |> slice_sample(n = 12) |>                # paid before DOS
  mutate(claim_line_id = paste0(claim_id, "-X1"),
         paid_date     = service_date - sample(5:60, n(), replace = TRUE))

missing_dos <- extract |> slice_sample(n = 8) |>               # no service date
  mutate(claim_line_id = paste0(claim_id, "-X2"),
         service_date  = as.Date(NA))

extract <- bind_rows(extract, dupes, bad_dates, missing_dos) |>
  slice_sample(prop = 1) |>                                    # shuffle like a real feed
  select(claim_line_id, claim_id, claim_freq_cd, claim_type, lob,
         service_date, paid_date, paid_amount)

dir.create("data", showWarnings = FALSE)
write_csv(extract, "data/paid_claims_extract.csv", na = "")
write_csv(truth,   "data/synthetic_true_ultimate.csv")

cat(sprintf("Wrote %d extract rows (%d full run-out lines; %d truth rows)\n",
            nrow(extract), nrow(full_runout), nrow(truth)))
