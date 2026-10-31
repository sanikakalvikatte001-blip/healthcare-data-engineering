#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# End-to-end run: claims -> stays -> index stays -> readmission flags -> rates
# Usage (from the project folder):  Rscript scripts/run_pipeline.R
# ---------------------------------------------------------------------------
suppressPackageStartupMessages(library(data.table))
invisible(lapply(list.files("R", pattern = "\\.R$", full.names = TRUE), source))

cfg <- readmit_config(2025L)
date_cols <- c("admit_date", "discharge_date", "received_date", "eff_date", "term_date", "dob")
read_typed <- function(path) {
  dt <- fread(path, colClasses = "character")
  for (col in intersect(date_cols, names(dt))) set(dt, j = col, value = as.IDate(dt[[col]]))
  dt
}
claims     <- read_typed("data/ip_claims.csv")
members    <- read_typed("data/members.csv")
enrollment <- read_typed("data/enrollment.csv")

# 1. current claim versions
current <- current_claim_versions(claims, cfg)
# 2. stays (transfer chaining)
stays   <- build_stays(current, cfg)
# 3. index eligibility
flagged <- select_index_stays(stays, members, enrollment, cfg)
# 4. readmission flags
flags   <- flag_readmissions(flagged, cfg)

# Reconciliation counts so a reviewer can trace every row.
cat("== Claim to stay reconciliation ==\n")
cat(sprintf("claim versions received ...... %d\n", nrow(claims)))
cat(sprintf("original claims .............. %d\n", uniqueN(claims$original_claim_id)))
cat(sprintf("voided (dropped) ............. %d\n", uniqueN(claims$original_claim_id) - nrow(current)))
cat(sprintf("current claims ............... %d\n", nrow(current)))
cat(sprintf("stays after transfer chaining  %d  (multi-claim stays: %d)\n",
            nrow(stays), sum(stays$n_claims > 1)))

cat("\n== Denominator waterfall ==\n")
wf <- index_waterfall(flagged); print(wf)

overall <- readmission_rates(flags)
by_fac  <- readmission_rates(flags, by = "final_facility")
cat("\n== Overall 30-day unplanned readmission rate ==\n"); print(overall)
cat(sprintf("index stays with only a planned return (not counted): %d\n",
            sum(flags$planned_readmit_only)))
cat("\n== By discharging facility ==\n"); print(by_fac)

# Contrast: the naive query many first drafts use - every raw claim row is a
# "stay", any later claim admitted 0-30 days after discharge is a "readmit".
naive <- claims[, .(member_id, claim_id, admit_date, discharge_date)]
naive[, `:=`(from = discharge_date, to = discharge_date + 30L)]
naive_hits <- naive[naive, on = .(member_id, admit_date >= from, admit_date <= to),
                    nomatch = NULL, .(claim_id = i.claim_id, other = x.claim_id)
                   ][claim_id != other, uniqueN(claim_id)]
cat(sprintf("\nNaive raw-claim approach: %d of %d claim rows flagged as readmitted (%.1f%%) - inflated by\n",
            naive_hits, nrow(naive), 100 * naive_hits / nrow(naive)))
cat("duplicate claim versions, transfers counted as readmits, planned/maternity stays and\nno denominator exclusions.\n")

dir.create("output", showWarnings = FALSE)
fwrite(stays,   "output/stays.csv")
fwrite(flags,   "output/index_stay_readmission_flags.csv")
fwrite(wf,      "output/denominator_waterfall.csv")
fwrite(by_fac,  "output/readmission_rate_by_facility.csv")
cat("\nOutputs written to output/\n")
