#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Synthetic data generator (no PHI - all IDs, dates and NPIs are fake).
#
# Writes three CSVs to data/:
#   members.csv      member_id, dob
#   enrollment.csv   member_id, eff_date, term_date   (raw segments)
#   ip_claims.csv    inpatient facility claim versions (UB-04 style)
#
# The data deliberately contains the messy cases the pipeline must handle:
# claim replacements and voids, acute-to-acute transfers, in-hospital
# deaths, minors, maternity stays, enrollment gaps, planned chemo returns.
# ---------------------------------------------------------------------------
suppressPackageStartupMessages(library(data.table))
set.seed(20261031)

n_members  <- 600L
facilities <- sprintf("19%08d", c(10011L, 20022L, 30033L, 40044L, 50055L))  # fake NPIs
fac_weight <- c(0.30, 0.25, 0.20, 0.15, 0.10)
fac_readmit_bias <- setNames(c(0.12, 0.16, 0.20, 0.10, 0.26), facilities)

medical_dx <- c("I50.9", "J44.1", "J18.9", "N17.9", "A41.9", "I21.4", "E11.65", "K57.32")

# --- members -----------------------------------------------------------------
members <- data.table(
  member_id = sprintf("M%05d", seq_len(n_members)),
  dob = as.IDate("2025-06-30") - as.integer(round(365.25 * runif(n_members, 19, 90)))
)
minor_idx <- sample(n_members, 18)                     # a few pediatric members
members[minor_idx, dob := as.IDate("2025-06-30") - as.integer(round(365.25 * runif(.N, 2, 16)))]

# --- enrollment (split into monthly-ish segments like a real 834 feed) ------
enroll <- members[, .(member_id)]
enroll[, `:=`(eff_date = as.IDate("2024-07-01"), term_date = as.IDate("2026-06-30"))]
gap_members  <- sample(members$member_id, 45)          # mid-year disenrollment
enroll[member_id %in% gap_members,
       term_date := as.IDate("2025-01-01") + sample(60:300, .N, replace = TRUE)]
# Split 30% of members into two touching segments - must merge back to one span.
split_members <- sample(setdiff(members$member_id, gap_members), 180)
seg2 <- enroll[member_id %in% split_members][, `:=`(eff_date = as.IDate("2025-07-01"))]
enroll[member_id %in% split_members, term_date := as.IDate("2025-06-30")]
enroll <- rbind(enroll, seg2)

# --- stays -------------------------------------------------------------------
stay_rows <- list()
for (m in members$member_id) {
  n_adm <- rpois(1, 0.85)
  if (n_adm == 0) next
  is_minor <- m %in% members$member_id[minor_idx]
  cur <- as.IDate("2024-12-20") + sample(0:120, 1)
  k <- 0L
  while (k < n_adm) {
    k <- k + 1L
    fac  <- sample(facilities, 1, prob = fac_weight)
    los  <- max(1L, rpois(1, 4))
    dx   <- if (!is_minor && runif(1) < 0.06) "O80" else sample(medical_dx, 1)
    stat <- if (runif(1) < 0.03) "20" else sample(c("01", "06", "03", "02"), 1, prob = c(.58, .25, .14, .03))
    stay_rows[[length(stay_rows) + 1]] <- list(m, fac, cur, cur + los, stat, dx)
    if (stat == "20") break

    # Direct transfer: discharge status 02, next hospital admits same day.
    if (runif(1) < 0.06) {
      stay_rows[[length(stay_rows)]][[5]] <- "02"
      fac2 <- sample(setdiff(facilities, fac), 1)
      t_admit <- cur + los
      stay_rows[[length(stay_rows) + 1]] <- list(m, fac2, t_admit, t_admit + max(1L, rpois(1, 3)), "01", dx)
      los <- as.integer(stay_rows[[length(stay_rows)]][[4]] - cur)
      fac <- fac2
    }
    disch <- cur + los

    r <- runif(1)
    if (r < fac_readmit_bias[[fac]]) {
      # Unplanned return 2-30 days later (adds one more admission to the member)
      cur <- disch + sample(2:30, 1)
      n_adm <- n_adm + 1L
    } else if (r < fac_readmit_bias[[fac]] + 0.05) {
      # Planned chemotherapy admission inside the window
      ra <- disch + sample(5:25, 1)
      stay_rows[[length(stay_rows) + 1]] <- list(m, fac, ra, ra + 2L, "01", "Z51.11")
      cur <- ra + 2L + sample(31:120, 1)
    } else {
      cur <- disch + sample(31:160, 1)
    }
    if (cur > as.IDate("2026-01-31")) break
  }
}
stays <- rbindlist(lapply(stay_rows, function(x) as.data.table(setNames(x,
  c("member_id", "facility_npi", "admit_date", "discharge_date", "discharge_status", "primary_dx")))))

# --- claims: originals, replacements and voids -------------------------------
claims <- copy(stays)
claims[, original_claim_id := sprintf("C%07d", seq_len(.N) + 1000000L)]
claims[, `:=`(claim_id = original_claim_id, freq_code = "1",
              received_date = discharge_date + sample(5:40, .N, replace = TRUE))]

# 9% replaced: newer version arrives later (discharge date corrected +1 day)
rep_ids <- sample(claims$original_claim_id, round(0.09 * nrow(claims)))
repl <- claims[original_claim_id %in% rep_ids]
repl[, `:=`(claim_id = paste0(original_claim_id, "R1"), freq_code = "7",
            received_date = received_date + sample(10:45, .N, replace = TRUE),
            discharge_date = discharge_date + sample(0:1, .N, replace = TRUE))]

# 2% voided: a billing error that should never count as a stay
void_ids <- sample(setdiff(claims$original_claim_id, rep_ids), round(0.02 * nrow(claims)))
voids <- claims[original_claim_id %in% void_ids]
voids[, `:=`(claim_id = paste0(original_claim_id, "V1"), freq_code = "8",
             received_date = received_date + 20L)]

claims <- rbind(claims, repl, voids)
claims[, bill_type := paste0("11", freq_code)]
setcolorder(claims, c("claim_id", "original_claim_id", "freq_code", "bill_type", "member_id",
                      "facility_npi", "admit_date", "discharge_date", "discharge_status",
                      "primary_dx", "received_date"))
setorder(claims, member_id, admit_date, received_date)

dir.create("data", showWarnings = FALSE)
fwrite(members, "data/members.csv")
fwrite(enroll[order(member_id, eff_date)], "data/enrollment.csv")
fwrite(claims, "data/ip_claims.csv")
cat(sprintf("members=%d enrollment_segments=%d claim_versions=%d (originals=%d, replacements=%d, voids=%d)\n",
            nrow(members), nrow(enroll), nrow(claims),
            sum(claims$freq_code == "1"), sum(claims$freq_code == "7"), sum(claims$freq_code == "8")))
