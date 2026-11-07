# Intake checks for a paid-claims extract.
#
# Each rule is a small named predicate (TRUE = row breaks the rule). Rules are
# applied in order and a row is tagged with the FIRST rule it fails, so the
# exception table has exactly one reason per rejected line.

claim_rules <- list(
  MISSING_SERVICE_DATE = function(d, val_date) is.na(d$service_date),
  MISSING_PAID_DATE    = function(d, val_date) is.na(d$paid_date),
  PAID_BEFORE_SERVICE  = function(d, val_date) d$paid_date < d$service_date,
  PAID_AFTER_VALUATION = function(d, val_date) d$paid_date > val_date,
  MISSING_AMOUNT       = function(d, val_date) is.na(d$paid_amount)
)

#' Read the extract with explicit column types (never let readr guess dates
#' or turn claim IDs into numbers).
read_paid_claims <- function(path) {
  readr::read_csv(
    path,
    col_types = readr::cols(
      claim_line_id = readr::col_character(),
      claim_id      = readr::col_character(),
      claim_freq_cd = readr::col_character(),
      claim_type    = readr::col_character(),
      lob           = readr::col_character(),
      service_date  = readr::col_date(),
      paid_date     = readr::col_date(),
      paid_amount   = readr::col_double()
    )
  )
}

#' Drop exact re-sends of the same claim line. A line is identified by
#' claim_line_id; if the same id arrives twice we keep one copy.
#' Reversals (freq 8) and replacements (freq 7) have their own line ids, so
#' they are NOT treated as duplicates - they net against the original.
dedupe_claim_lines <- function(claims) {
  claims |>
    dplyr::distinct(claim_line_id, .keep_all = TRUE)
}

#' Split claims into clean rows and an exception table.
#' Returns list(clean = <tibble>, exceptions = <tibble with reason_code>).
validate_claims <- function(claims, valuation_date, rules = claim_rules) {
  valuation_date <- as.Date(valuation_date)

  # Evaluate every rule; NA results (e.g. comparing to a missing date) are
  # treated as "not failed" here because an earlier rule already catches them.
  failed <- purrr::map(rules, function(rule) {
    out <- rule(claims, valuation_date)
    !is.na(out) & out
  })

  # First failing rule wins
  reason <- rep(NA_character_, nrow(claims))
  for (code in names(failed)) {
    reason[is.na(reason) & failed[[code]]] <- code
  }

  list(
    clean      = claims[is.na(reason), ],
    exceptions = dplyr::mutate(claims[!is.na(reason), ],
                               reason_code = reason[!is.na(reason)])
  )
}
