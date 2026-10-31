# ---------------------------------------------------------------------------
# Measure configuration
#
# Kept in one plain list so the business rules are easy to review with a
# quality/analytics team and easy to change (e.g. a different measurement
# year) without touching the pipeline functions.
# ---------------------------------------------------------------------------

readmit_config <- function(measurement_year = 2025L) {
  list(
    # Index discharges must fall between Jan 1 and Dec 1 so every index stay
    # has a full 30-day follow-up window inside the year.
    period_start      = as.IDate(sprintf("%d-01-01", measurement_year)),
    period_end        = as.IDate(sprintf("%d-12-01", measurement_year)),
    followup_days     = 30L,

    # Two claims are one stay when the next admit is on the same day or the
    # day after the prior discharge (direct acute-to-acute transfer).
    transfer_gap_days = 1L,

    min_age           = 18L,

    # UB-04 patient discharge status codes
    status_expired      = c("20"),
    status_transfer_out = c("02", "05", "66"),   # short-term acute / cancer / CAH

    # Claim frequency code (3rd digit of bill type): 8 = void / cancel
    freq_void = "8",

    # ICD-10-CM prefixes. Maternity and perinatal stays are excluded both
    # as index stays and as readmissions.
    maternity_dx_prefix = c("O", "Z37", "Z38", "P"),

    # Planned readmissions are not counted (simplified planned-readmission
    # list: chemotherapy, radiotherapy, rehab, transplant follow-up).
    planned_dx_prefix = c("Z510", "Z5111", "Z5112", "Z5189", "Z5089", "Z940", "Z941")
  )
}

# Vectorised "starts with any of these prefixes" helper for ICD-10 codes.
# Codes are compared without the dot (O80 == O80, Z51.11 == Z5111).
dx_has_prefix <- function(dx, prefixes) {
  dx <- gsub(".", "", toupper(dx), fixed = TRUE)
  if (length(dx) == 0L) return(logical(0))
  Reduce(`|`, lapply(prefixes, function(p) startsWith(dx, p)))
}
