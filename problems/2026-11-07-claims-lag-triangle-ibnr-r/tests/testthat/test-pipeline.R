# End-to-end run on the generated synthetic extract.

cfg <- load_config(file.path(project_root, "config.yml"))
cfg$paths <- lapply(cfg$paths, function(p) file.path(project_root, p))
res <- run_pipeline(cfg)

test_that("intake counts reconcile: raw - dupes = exceptions + clean", {
  n <- setNames(res$intake$rows, res$intake$stage)
  expect_equal(n[["after_dedupe"]], n[["exceptions"]] + n[["clean_rows"]])
  expect_equal(n[["raw_rows"]] - n[["after_dedupe"]], 40)   # injected re-sends
  expect_setequal(unique(res$exceptions$reason_code),
                  c("MISSING_SERVICE_DATE", "PAID_BEFORE_SERVICE"))
})

test_that("total paid in the triangle equals total clean paid", {
  clean_total <- read_paid_claims(cfg$paths$claims) |>
    dedupe_claim_lines() |>
    validate_claims(cfg$valuation_date) |>
    purrr::pluck("clean") |>
    summarise(x = sum(paid_amount)) |>
    pull(x)
  expect_equal(sum(res$triangle$incremental_paid), clean_total, tolerance = 1e-8)
})

test_that("every segment has one projection row per incurred month", {
  per_seg <- count(res$projection, claim_type)
  expect_true(all(per_seg$n == 30))                  # Jan 2024 - Jun 2026
})

test_that("facility claims pay slower than professional claims", {
  lp <- res$lag_profile
  expect_gt(lp$median_lag_days[lp$claim_type == "Institutional"],
            lp$median_lag_days[lp$claim_type == "Professional"])
  cf3 <- filter(res$factors, lag == 3)
  expect_gt(cf3$completion_factor[cf3$claim_type == "Professional"],
            cf3$completion_factor[cf3$claim_type == "Institutional"])
})

test_that("completion is 100% at the last modelled lag", {
  last <- filter(res$factors, lag == cfg$max_dev_lag)
  expect_equal(last$completion_factor, c(1, 1))
})

test_that("projection beats raw paid-to-date against the synthetic truth", {
  bt <- backtest(res$projection, cfg$paths$truth, "claim_type")
  recent <- filter(bt, current_lag <= 6)
  expect_lt(mean(abs(recent$pct_error_projected)),
            mean(abs(recent$pct_error_paid_only)))
  # Mature months (6+ months of run-out) are within 7% of truth
  expect_lt(max(abs(filter(bt, current_lag >= 6)$pct_error_projected)), 0.07)
})
