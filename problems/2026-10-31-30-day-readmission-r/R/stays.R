# ---------------------------------------------------------------------------
# Step 1 and 2: raw facility claims -> one row per acute inpatient stay
# ---------------------------------------------------------------------------

#' Keep only the current version of each claim.
#'
#' Payers receive originals (freq 1), replacements (freq 7) and voids
#' (freq 8) that all point back to the same original claim. Counting every
#' version double-counts admissions; the newest version wins, and if the
#' newest version is a void the claim disappears.
#'
#' @param claims data.table with original_claim_id, freq_code, received_date
#' @return data.table of active, current-version claims
current_claim_versions <- function(claims, cfg = readmit_config()) {
  dt <- copy(as.data.table(claims))
  setorder(dt, original_claim_id, -received_date, -claim_id)
  latest <- dt[, .SD[1L], by = original_claim_id]
  latest[freq_code != cfg$freq_void]
}

#' Chain claims into stays (direct-transfer logic).
#'
#' A member transferred from Hospital A to Hospital B generates two claims
#' but is one episode of acute care. Readmission measures treat the chain
#' as a single stay that runs from the first admit to the last discharge,
#' and the transfer itself must never look like a readmission.
#'
#' Overlapping claims (interim bills, late corrections) are absorbed by
#' comparing each admit to the running maximum discharge date seen so far.
#'
#' @return data.table, one row per stay
build_stays <- function(claims, cfg = readmit_config()) {
  dt <- copy(as.data.table(claims))
  setorder(dt, member_id, admit_date, discharge_date)

  # Running max of discharge date from all *previous* claims of the member.
  dt[, prev_max_disch := shift(cummax(as.integer(discharge_date))), by = member_id]
  dt[, new_stay := is.na(prev_max_disch) |
                   as.integer(admit_date) > prev_max_disch + cfg$transfer_gap_days]
  dt[, stay_seq := cumsum(new_stay), by = member_id]

  stays <- dt[, .(
    admit_date       = min(admit_date),
    discharge_date   = max(discharge_date),
    # Status and facility come from the claim that closes the stay.
    discharge_status = discharge_status[which.max(discharge_date)],
    final_facility   = facility_npi[which.max(discharge_date)],
    first_facility   = facility_npi[1L],
    # The admitting claim's principal dx describes why the member came in;
    # this is what the planned-readmission rule looks at.
    principal_dx     = primary_dx[1L],
    all_dx           = paste(unique(primary_dx), collapse = "|"),
    n_claims         = .N,
    claim_ids        = paste(claim_id, collapse = "|")
  ), by = .(member_id, stay_seq)]

  stays[, stay_id := sprintf("%s-S%02d", member_id, stay_seq)]
  stays[, los_days := as.integer(discharge_date - admit_date)]
  stays[, is_maternity := vapply(strsplit(all_dx, "|", fixed = TRUE),
                                 function(x) any(dx_has_prefix(x, cfg$maternity_dx_prefix)),
                                 logical(1))]
  stays[, is_planned := dx_has_prefix(principal_dx, cfg$planned_dx_prefix)]
  stays[, stay_seq := NULL]
  setcolorder(stays, c("stay_id", "member_id"))
  stays[]
}
