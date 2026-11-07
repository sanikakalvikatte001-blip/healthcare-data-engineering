val <- as.Date("2026-03-31")

test_that("months_between counts calendar months across year ends", {
  expect_equal(months_between(as.Date("2025-11-01"), as.Date("2026-02-01")), 3)
  expect_equal(months_between(as.Date("2026-03-01"), as.Date("2026-03-31")), 0)
})

test_that("triangle has only observable cells with correct cumulative paid", {
  tri <- build_triangle(toy_claims(), val, max_dev_lag = 2)
  expect_equal(nrow(tri), 6)                         # 3 + 2 + 1 cells
  jan <- filter(tri, incurred_month == as.Date("2026-01-01"))
  expect_equal(jan$cumulative_paid, c(100, 150, 160))
  feb <- filter(tri, incurred_month == as.Date("2026-02-01"))
  expect_equal(feb$cumulative_paid, c(200, 280))
})

test_that("gaps are zero-filled and late payments fold into the last lag", {
  claims <- tibble::tibble(
    service_date = as.Date(c("2026-01-10", "2026-01-12")),
    paid_date    = as.Date(c("2026-01-30", "2026-03-15")),   # lag 0 and lag 2
    paid_amount  = c(10, 5)
  )
  jan <- as.Date("2026-01-01")
  tri <- build_triangle(claims, val, max_dev_lag = 1) |> filter(incurred_month == jan)
  expect_equal(tri$lag, c(0, 1))
  expect_equal(tri$incremental_paid, c(10, 5))      # lag-2 payment folded into lag 1

  tri2 <- build_triangle(claims, val, max_dev_lag = 3) |> filter(incurred_month == jan)
  expect_equal(tri2$incremental_paid, c(10, 0, 5))  # lag 1 had no payments
})

test_that("an incurred month with nothing paid yet still appears when history_start is set", {
  tri <- build_triangle(filter(toy_claims(), service_date < as.Date("2026-03-01")),
                        val, max_dev_lag = 2, history_start = "2026-01-01")
  mar <- filter(tri, incurred_month == as.Date("2026-03-01"))
  expect_equal(nrow(mar), 1)
  expect_equal(mar$cumulative_paid, 0)
})

test_that("age-to-age factors are volume weighted and respect the window", {
  tri <- build_triangle(toy_claims(), val, max_dev_lag = 2)

  f_all <- age_to_age_factors(tri, max_dev_lag = 2, window = 12)
  expect_equal(f_all$factor, c((150 + 280) / (100 + 200), 160 / 150))
  expect_equal(f_all$n_months, c(2L, 1L))

  f_recent <- age_to_age_factors(tri, max_dev_lag = 2, window = 1)
  expect_equal(f_recent$factor[1], 280 / 200)       # Feb only
})

test_that("completion factors chain the age-to-age factors to the end", {
  cf <- completion_factors(tibble::tibble(lag = 0:1, factor = c(1.5, 1.1)))
  expect_equal(cf$cdf, c(1.5 * 1.1, 1.1, 1))
  expect_equal(cf$completion_factor, 1 / c(1.65, 1.1, 1))
})

test_that("chain-ladder ultimate = paid to date x CDF; reporting gate applied", {
  tri <- build_triangle(toy_claims(), val, max_dev_lag = 2)
  cf  <- completion_factors(age_to_age_factors(tri, 2, 12))
  p   <- project_ultimate(tri, cf, threshold = 0.95)

  f0 <- 430 / 300; f1 <- 160 / 150
  expect_equal(p$est_ultimate, c(160, 280 * f1, 50 * f0 * f1))
  expect_equal(p$ibnr, p$est_ultimate - p$paid_to_date)
  expect_equal(p$reportable, c(TRUE, FALSE, FALSE))
  expect_true(all(p$method == "chain_ladder"))
})

test_that("Bornhuetter-Ferguson replaces chain ladder for immature months", {
  tri <- build_triangle(toy_claims(), val, max_dev_lag = 2)
  cf  <- completion_factors(age_to_age_factors(tri, 2, 12))
  p   <- project_ultimate(tri, cf, threshold = 0.95, bf_below = 0.80, bf_prior_months = 6)

  mar <- filter(p, incurred_month == as.Date("2026-03-01"))
  expect_equal(mar$method, "bornhuetter_ferguson")
  # Expected ultimate = Jan (the only reportable month) = 160
  expect_equal(mar$est_ultimate, 50 + (1 - mar$completion_factor) * 160)
  # Feb is ~94% complete -> stays on chain ladder
  expect_equal(filter(p, incurred_month == as.Date("2026-02-01"))$method, "chain_ladder")
})
