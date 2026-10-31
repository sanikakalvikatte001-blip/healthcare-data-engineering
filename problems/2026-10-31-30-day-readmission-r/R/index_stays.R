# ---------------------------------------------------------------------------
# Step 3: decide which stays are eligible index discharges
#
# Every exclusion is recorded as a reason (first failing rule wins) so the
# denominator can be explained to a quality team as a waterfall instead of
# a single unexplained number.
# ---------------------------------------------------------------------------

#' Whole years between two dates (birthday-aware, handles Feb 29).
age_on <- function(dob, as_of) {
  dob <- as.POSIXlt(dob); as_of <- as.POSIXlt(as_of)
  age <- as_of$year - dob$year
  before_bday <- (as_of$mon < dob$mon) |
                 (as_of$mon == dob$mon & as_of$mday < dob$mday)
  as.integer(age - before_bday)
}

#' Collapse enrollment segments that touch or overlap into continuous spans.
merge_enrollment_spans <- function(enrollment) {
  en <- copy(as.data.table(enrollment))
  setorder(en, member_id, eff_date)
  en[, prev_max_term := shift(cummax(as.integer(term_date))), by = member_id]
  en[, span_seq := cumsum(is.na(prev_max_term) | as.integer(eff_date) > prev_max_term + 1L),
     by = member_id]
  en[, .(eff_date = min(eff_date), term_date = max(term_date)), by = .(member_id, span_seq)
     ][, span_seq := NULL][]
}

#' Flag each stay with an index-eligibility reason.
#'
#' @param stays      output of build_stays()
#' @param members    member_id, dob
#' @param enrollment member_id, eff_date, term_date (raw segments)
#' @return stays with `exclusion_reason` (NA = eligible) and `is_index`
select_index_stays <- function(stays, members, enrollment, cfg = readmit_config()) {
  st <- copy(stays)
  st <- merge(st, as.data.table(members)[, .(member_id, dob)], by = "member_id", all.x = TRUE)
  st[, age_at_discharge := age_on(dob, discharge_date)]

  # Continuous enrollment from discharge through discharge + 30 days, with
  # no gap. A non-equi join finds a single merged span covering the window.
  spans <- merge_enrollment_spans(enrollment)
  st[, `:=`(win_start = discharge_date, win_end = discharge_date + cfg$followup_days)]
  covered <- spans[st, on = .(member_id, eff_date <= win_start, term_date >= win_end),
                   nomatch = NULL, .(stay_id = i.stay_id)]
  st[, enrolled_30d := stay_id %in% covered$stay_id]

  # Waterfall - order matters, the first rule that fails is reported.
  st[, exclusion_reason := fcase(
    discharge_date < cfg$period_start | discharge_date > cfg$period_end, "discharge outside period",
    discharge_status %in% cfg$status_expired,                           "died during stay",
    discharge_status %in% cfg$status_transfer_out,                      "transferred out to acute care",
    is.na(age_at_discharge) | age_at_discharge < cfg$min_age,           "under 18 at discharge",
    is_maternity,                                                       "maternity / perinatal",
    !enrolled_30d,                                                      "not enrolled 30 days post-discharge",
    default = NA_character_
  )]
  st[, is_index := is.na(exclusion_reason)]
  st[, c("win_start", "win_end", "dob") := NULL]
  st[]
}

#' Denominator waterfall: how many stays each rule removed.
index_waterfall <- function(flagged_stays) {
  rules <- c("discharge outside period", "died during stay",
             "transferred out to acute care", "under 18 at discharge",
             "maternity / perinatal", "not enrolled 30 days post-discharge")
  removed <- flagged_stays[, .N, by = exclusion_reason]
  out <- data.table(step = c("all stays", rules, "eligible index stays"))
  out[, stays_removed := c(NA_integer_,
                           vapply(rules, function(r) removed[exclusion_reason %in% r, sum(N)], integer(1)),
                           NA_integer_)]
  out[, stays_remaining := c(nrow(flagged_stays),
                             nrow(flagged_stays) - cumsum(stays_removed[2:(length(rules) + 1)]),
                             sum(flagged_stays$is_index))]
  out[]
}
