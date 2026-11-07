test_that("duplicate line ids collapse but reversals and replacements survive", {
  claims <- tibble::tibble(
    claim_line_id = c("A-01", "A-01", "A-R1", "A-A1"),
    claim_freq_cd = c("1", "1", "8", "7"),
    paid_amount   = c(100, 100, -100, 90)
  )
  out <- dedupe_claim_lines(claims)
  expect_equal(nrow(out), 3)
  expect_equal(sum(out$paid_amount), 90)          # original - reversal + replacement
})

test_that("each rejected row gets exactly one reason, first rule wins", {
  claims <- toy_claims() |>
    bind_rows(tibble::tibble(
      claim_line_id = c("X-1", "X-2", "X-3", "X-4"),
      service_date  = as.Date(c(NA, "2026-02-10", "2026-02-10", "2026-02-10")),
      paid_date     = as.Date(c("2026-01-01", "2026-02-01", "2026-04-15", NA)),
      paid_amount   = c(10, 10, 10, 10)
    ))
  res <- validate_claims(claims, "2026-03-31")

  expect_equal(nrow(res$clean), 6)
  expect_equal(nrow(res$exceptions), 4)
  expect_equal(
    res$exceptions$reason_code[order(res$exceptions$claim_line_id)],
    c("MISSING_SERVICE_DATE", "PAID_BEFORE_SERVICE",
      "PAID_AFTER_VALUATION", "MISSING_PAID_DATE")
  )
  # Nothing is lost: clean + exceptions = input
  expect_equal(nrow(res$clean) + nrow(res$exceptions), nrow(claims))
})

test_that("a missing service AND paid date is reported once, as missing service date", {
  claims <- tibble::tibble(claim_line_id = "Z", service_date = as.Date(NA),
                           paid_date = as.Date(NA), paid_amount = 1)
  res <- validate_claims(claims, "2026-03-31")
  expect_equal(res$exceptions$reason_code, "MISSING_SERVICE_DATE")
})
