# Command-line entry point.
#   Rscript run_pipeline.R [config.yml]
# Writes CSV outputs to output/ and prints a short run summary.

options(width = 140)
suppressPackageStartupMessages({
  library(dplyr)
})

source("R/pipeline.R")
source_lib(".")

args <- commandArgs(trailingOnly = TRUE)
cfg  <- load_config(if (length(args) > 0) args[[1]] else "config.yml")

res <- run_pipeline(cfg)
write_outputs(res, cfg$paths$output)

bt <- backtest(res$projection, cfg$paths$truth, cfg$segment_by)
readr::write_csv(
  mutate(bt, across(where(is.double), ~ round(.x, 4))),
  file.path(cfg$paths$output, "backtest_vs_synthetic_truth.csv")
)

cat("\n== Intake ==\n");               print(res$intake)
cat("\n== Exceptions by reason ==\n"); print(count(res$exceptions, reason_code))
cat("\n== Payment lag profile ==\n");  print(res$lag_profile)

cat("\n== Recent incurred months ==\n")
res$projection |>
  filter(incurred_month >= cfg$valuation_date - 180) |>
  mutate(across(c(paid_to_date, est_ultimate, ibnr), round),
         completion_factor = round(completion_factor, 3)) |>
  print(n = 20)

cat("\n== Backtest: last 6 incurred months, all segments ==\n")
bt |>
  filter(incurred_month >= as.Date("2026-01-01")) |>
  group_by(incurred_month) |>
  summarise(paid_to_date = sum(paid_to_date), est_ultimate = sum(est_ultimate),
            true_ultimate = sum(true_ultimate_paid), .groups = "drop") |>
  mutate(err_paid_only = round(paid_to_date / true_ultimate - 1, 3),
         err_projected = round(est_ultimate / true_ultimate - 1, 3)) |>
  print()
