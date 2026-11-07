# Lag triangle and chain-ladder completion factors.
#
# Vocabulary
#   incurred month : month of the service date (when the cost happened)
#   lag            : whole months from incurred month to paid month (0 = paid in
#                    the same month it was incurred)
#   cumulative paid: net paid for an incurred month through a given lag
#   completion factor (CF) at lag k: share of the ultimate cost that is
#                    typically paid by lag k. Ultimate = paid_to_date / CF.

#' Whole-month difference between two dates' months (vectorised).
months_between <- function(from, to) {
  (lubridate::year(to) - lubridate::year(from)) * 12 +
    (lubridate::month(to) - lubridate::month(from))
}

#' Add incurred month, paid month and lag columns.
add_lag <- function(claims) {
  claims |>
    dplyr::mutate(
      incurred_month = lubridate::floor_date(service_date, "month"),
      paid_month     = lubridate::floor_date(paid_date, "month"),
      lag_days       = as.integer(paid_date - service_date),
      lag_months     = months_between(incurred_month, paid_month)
    )
}

#' Build the long-format lag triangle.
#'
#' One row per (incurred_month, lag) cell that is observable at the valuation
#' date, with zero-filled gaps so cumulative sums are correct. Payments later
#' than max_dev_lag are folded into the last lag bucket.
build_triangle <- function(claims, valuation_date, max_dev_lag,
                           history_start = NULL) {
  val_month <- lubridate::floor_date(as.Date(valuation_date), "month")

  lagged <- claims |>
    add_lag() |>
    dplyr::mutate(lag = pmin(lag_months, max_dev_lag))

  if (!is.null(history_start)) {
    lagged <- dplyr::filter(lagged, incurred_month >= as.Date(history_start))
  }

  cells <- lagged |>
    dplyr::group_by(incurred_month, lag) |>
    dplyr::summarise(incremental_paid = sum(paid_amount), .groups = "drop")

  # Every incurred month gets every lag it has "lived through" so far. When a
  # history start is given, months with NO payments yet (common for facility
  # claims in the current month) still get a zero row instead of vanishing.
  first_month <- if (is.null(history_start)) min(cells$incurred_month) else
    lubridate::floor_date(as.Date(history_start), "month")
  months <- seq(first_month, val_month, by = "month")
  grid <- tidyr::expand_grid(incurred_month = months, lag = 0:max_dev_lag) |>
    dplyr::filter(lag <= pmin(months_between(incurred_month, val_month), max_dev_lag))

  grid |>
    dplyr::left_join(cells, by = c("incurred_month", "lag")) |>
    dplyr::mutate(incremental_paid = dplyr::coalesce(incremental_paid, 0)) |>
    dplyr::arrange(incurred_month, lag) |>
    dplyr::group_by(incurred_month) |>
    dplyr::mutate(cumulative_paid = cumsum(incremental_paid)) |>
    dplyr::ungroup()
}

#' Pivot the long triangle to the familiar wide layout (rows = incurred month,
#' columns = lag) for display / export.
triangle_wide <- function(triangle, value = cumulative_paid) {
  triangle |>
    dplyr::select(incurred_month, lag, {{ value }}) |>
    tidyr::pivot_wider(names_from = lag, values_from = {{ value }},
                       names_prefix = "lag_")
}

#' Volume-weighted age-to-age factors.
#'
#' factor(k) = sum C[i, k+1] / sum C[i, k], over the most recent `window`
#' incurred months that have reached lag k+1. Lags with no usable data get 1.0.
age_to_age_factors <- function(triangle, max_dev_lag, window) {
  pairs <- triangle |>
    dplyr::select(incurred_month, lag, cumulative_paid) |>
    dplyr::inner_join(
      triangle |>
        dplyr::transmute(incurred_month, lag = lag - 1, next_cumulative = cumulative_paid),
      by = c("incurred_month", "lag")
    )

  factors <- pairs |>
    dplyr::group_by(lag) |>
    dplyr::slice_max(incurred_month, n = window) |>   # most recent N months per lag
    dplyr::summarise(
      n_months = dplyr::n(),
      factor   = sum(next_cumulative) / sum(cumulative_paid),
      .groups  = "drop"
    )

  tibble::tibble(lag = 0:(max_dev_lag - 1)) |>
    dplyr::left_join(factors, by = "lag") |>
    dplyr::mutate(
      n_months = dplyr::coalesce(n_months, 0L),
      factor   = dplyr::if_else(is.na(factor) | !is.finite(factor), 1, factor)
    )
}

#' Cumulative development factor and completion factor for every lag.
#' CDF(k) = product of age-to-age factors from k to the end; CF(k) = 1 / CDF(k).
#' At the final lag CDF = 1 (no tail factor).
completion_factors <- function(factors) {
  f <- c(factors$factor, 1)               # append the terminal lag
  cdf <- rev(cumprod(rev(f)))
  tibble::tibble(
    lag               = c(factors$lag, max(factors$lag) + 1),
    cdf               = cdf,
    completion_factor = 1 / cdf
  )
}

#' Project ultimate cost and IBNR for each incurred month, and apply the
#' reporting gate (completion >= threshold).
#'
#' Chain ladder (paid_to_date x CDF) is unstable when very little has been
#' paid: one large facility claim in the current month can triple the
#' estimate, and a month with nothing paid projects to zero. Below
#' `bf_below` completion we switch to Bornhuetter-Ferguson:
#'   ultimate = paid_to_date + (1 - CF) x expected_ultimate
#' where expected_ultimate is the mean chain-ladder ultimate of the
#' `bf_prior_months` most recent months that already pass the reporting gate.
project_ultimate <- function(triangle, cf, threshold,
                             bf_below = 0, bf_prior_months = 6) {
  proj <- triangle |>
    dplyr::group_by(incurred_month) |>
    dplyr::slice_max(lag, n = 1) |>                   # latest observed diagonal
    dplyr::ungroup() |>
    dplyr::transmute(incurred_month, current_lag = lag, paid_to_date = cumulative_paid) |>
    dplyr::left_join(cf, by = c("current_lag" = "lag")) |>
    dplyr::mutate(
      cl_ultimate = paid_to_date * cdf,
      reportable  = completion_factor >= threshold
    )

  # A-priori expectation from the most recent credible (reportable) months
  expected <- proj |>
    dplyr::filter(reportable) |>
    dplyr::slice_max(incurred_month, n = bf_prior_months) |>
    dplyr::pull(cl_ultimate) |>
    mean()

  proj |>
    dplyr::mutate(
      method = dplyr::if_else(completion_factor < bf_below & !is.na(expected),
                              "bornhuetter_ferguson", "chain_ladder"),
      est_ultimate = dplyr::if_else(
        method == "bornhuetter_ferguson",
        paid_to_date + (1 - completion_factor) * expected,
        cl_ultimate
      ),
      ibnr = est_ultimate - paid_to_date
    ) |>
    dplyr::select(incurred_month, current_lag, paid_to_date, completion_factor,
                  method, est_ultimate, ibnr, reportable)
}
