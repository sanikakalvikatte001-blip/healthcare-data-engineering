# ---------------------------------------------------------------------------
# Step 4 and 5: flag 30-day readmissions and roll up rates
# ---------------------------------------------------------------------------

#' Flag each index stay with its first unplanned readmission within 30 days.
#'
#' Candidate readmissions are any later stay for the same member (they do
#' not have to be index-eligible themselves - e.g. a readmission in which
#' the member died still counts). Planned and maternity stays are not
#' counted as readmissions. A stay can be both a readmission for an earlier
#' stay and an index stay of its own, as in HEDIS PCR.
#'
#' @param flagged_stays output of select_index_stays()
#' @return one row per index stay with readmission columns
flag_readmissions <- function(flagged_stays, cfg = readmit_config()) {
  idx <- flagged_stays[is_index == TRUE,
                       .(stay_id, member_id, admit_date, discharge_date,
                         final_facility, principal_dx)]
  idx[, `:=`(win_from = discharge_date + 1L,
             win_to   = discharge_date + cfg$followup_days)]

  cand <- flagged_stays[is_maternity == FALSE,
                        .(member_id, readmit_stay_id = stay_id,
                          readmit_admit_date = admit_date, readmit_planned = is_planned,
                          readmit_dx = principal_dx)]
  cand[, admit_key := readmit_admit_date]

  # Non-equi join: every later stay that starts inside the 30-day window.
  hits <- cand[idx, on = .(member_id, admit_key >= win_from, admit_key <= win_to),
               nomatch = NULL,
               .(stay_id = i.stay_id, readmit_stay_id, readmit_admit_date,
                 readmit_planned, readmit_dx, index_discharge = i.discharge_date)]

  planned_only <- hits[, .(has_planned = any(readmit_planned)), by = stay_id]

  # First *unplanned* readmission per index stay.
  first_unplanned <- hits[readmit_planned == FALSE
                          ][order(stay_id, readmit_admit_date)
                          ][, .SD[1L], by = stay_id]
  first_unplanned[, days_to_readmit := as.integer(readmit_admit_date - index_discharge)]

  out <- merge(idx[, .(stay_id, member_id, admit_date, discharge_date, final_facility, principal_dx)],
               first_unplanned[, .(stay_id, readmit_stay_id, readmit_admit_date,
                                   days_to_readmit, readmit_dx)],
               by = "stay_id", all.x = TRUE)
  out <- merge(out, planned_only, by = "stay_id", all.x = TRUE)
  out[, readmitted_30d := !is.na(readmit_stay_id)]
  out[, planned_readmit_only := !readmitted_30d & !is.na(has_planned) & has_planned]
  out[, has_planned := NULL]
  setorder(out, member_id, discharge_date)
  out[]
}

#' Observed readmission rate overall and by discharging facility.
readmission_rates <- function(index_flags, by = NULL) {
  index_flags[, .(
    index_stays      = .N,
    readmissions     = sum(readmitted_30d),
    readmit_rate_pct = round(100 * mean(readmitted_30d), 1),
    median_days      = as.numeric(median(days_to_readmit, na.rm = TRUE))
  ), by = by][order(-readmit_rate_pct)]
}
