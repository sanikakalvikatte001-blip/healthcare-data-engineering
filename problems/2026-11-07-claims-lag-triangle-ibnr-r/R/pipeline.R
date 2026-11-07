# Config-driven pipeline: extract -> validate -> dedupe -> per-segment
# triangle -> factors -> completion / IBNR -> reporting gate.
#
# Each segment (claim type by default) is developed on its own triangle using
# a nested tibble + purrr::map, so adding a segment is a config change.

source_lib <- function(root = ".") {
  for (f in c("validate.R", "chain_ladder.R")) source(file.path(root, "R", f))
}

load_config <- function(path = "config.yml") {
  cfg <- yaml::read_yaml(path)
  cfg$valuation_date <- as.Date(cfg$valuation_date)
  cfg$history_start  <- as.Date(cfg$history_start)
  cfg
}

#' Payment-lag profile in days (service date -> paid date) by segment.
#' Uses original lines only so reversals do not distort the timing picture.
lag_profile <- function(claims, segment_col) {
  claims |>
    add_lag() |>
    dplyr::filter(claim_freq_cd == "1") |>
    dplyr::group_by(.data[[segment_col]]) |>
    dplyr::summarise(
      claim_lines      = dplyr::n(),
      median_lag_days  = stats::median(lag_days),
      p90_lag_days     = unname(stats::quantile(lag_days, 0.90)),
      pct_paid_30d     = mean(lag_days <= 30),
      pct_paid_90d     = mean(lag_days <= 90),
      .groups = "drop"
    )
}

#' Develop one segment's claims into triangle, factors and projections.
develop_segment <- function(claims, cfg) {
  tri <- build_triangle(claims, cfg$valuation_date, cfg$max_dev_lag, cfg$history_start)
  ata <- age_to_age_factors(tri, cfg$max_dev_lag, cfg$factor_window)
  cf  <- completion_factors(ata)
  list(
    triangle   = tri,
    factors    = dplyr::left_join(cf, ata, by = "lag"),
    projection = project_ultimate(tri, cf, cfg$completeness_threshold,
                                  bf_below        = cfg$bf_below_completion,
                                  bf_prior_months = cfg$bf_prior_months)
  )
}

run_pipeline <- function(cfg) {
  raw <- read_paid_claims(cfg$paths$claims)

  deduped    <- dedupe_claim_lines(raw)
  checked    <- validate_claims(deduped, cfg$valuation_date)
  clean      <- checked$clean
  seg        <- cfg$segment_by

  segments <- clean |>
    tidyr::nest(claims = -dplyr::all_of(seg)) |>
    dplyr::mutate(result = purrr::map(claims, develop_segment, cfg = cfg))

  pull_part <- function(part) {
    segments |>
      dplyr::mutate(x = purrr::map(result, part)) |>
      dplyr::select(dplyr::all_of(seg), x) |>
      tidyr::unnest(x)
  }

  list(
    intake = tibble::tibble(
      stage = c("raw_rows", "after_dedupe", "exceptions", "clean_rows"),
      rows  = c(nrow(raw), nrow(deduped), nrow(checked$exceptions), nrow(clean))
    ),
    exceptions  = checked$exceptions,
    lag_profile = lag_profile(clean, seg),
    triangle    = pull_part("triangle"),
    factors     = pull_part("factors"),
    projection  = pull_part("projection")
  )
}

#' Compare projected ultimate with the synthetic ground truth.
backtest <- function(projection, truth_path, segment_col) {
  truth <- readr::read_csv(truth_path, show_col_types = FALSE) |>
    dplyr::mutate(incurred_month = as.Date(incurred_month))
  projection |>
    dplyr::inner_join(truth, by = c(segment_col, "incurred_month")) |>
    dplyr::mutate(
      pct_error_paid_only = paid_to_date / true_ultimate_paid - 1,
      pct_error_projected = est_ultimate / true_ultimate_paid - 1
    )
}

write_outputs <- function(res, out_dir) {
  dir.create(out_dir, showWarnings = FALSE)
  fmt <- function(df) dplyr::mutate(df, dplyr::across(dplyr::where(is.double), ~ round(.x, 4)))
  readr::write_csv(res$intake,               file.path(out_dir, "intake_counts.csv"))
  readr::write_csv(res$exceptions,           file.path(out_dir, "claim_exceptions.csv"), na = "")
  readr::write_csv(fmt(res$lag_profile),     file.path(out_dir, "lag_profile.csv"))
  readr::write_csv(fmt(res$factors),         file.path(out_dir, "completion_factors.csv"))
  readr::write_csv(fmt(res$projection),      file.path(out_dir, "ibnr_by_incurred_month.csv"))
  wide <- res$triangle |>
    tidyr::nest(t = -1) |>
    dplyr::mutate(t = purrr::map(t, triangle_wide)) |>
    tidyr::unnest(t)
  readr::write_csv(fmt(wide), file.path(out_dir, "cumulative_paid_triangle.csv"), na = "")
}
