test_that("replacement claim supersedes the original", {
  cl <- rbind(
    claim("A", "2025-03-01", "2025-03-05", claim_id = "C1", status = "01"),
    claim("A", "2025-03-01", "2025-03-06", claim_id = "C1R", orig = "C1", freq = "7",
          received = "2025-04-30", status = "20"))
  cur <- current_claim_versions(cl)
  expect_equal(nrow(cur), 1L)
  expect_equal(cur$claim_id, "C1R")
  expect_equal(cur$discharge_status, "20")
})

test_that("voided claim removes the stay entirely", {
  cl <- rbind(
    claim("A", "2025-03-01", "2025-03-05", claim_id = "C1"),
    claim("A", "2025-03-01", "2025-03-05", claim_id = "C1V", orig = "C1", freq = "8",
          received = "2025-05-01"))
  expect_equal(nrow(current_claim_versions(cl)), 0L)
})

test_that("same-day and next-day transfers chain into one stay", {
  cl <- rbind(
    claim("A", "2025-03-01", "2025-03-05", status = "02", fac = "F1"),
    claim("A", "2025-03-05", "2025-03-09", status = "02", fac = "F2"),   # same day
    claim("A", "2025-03-10", "2025-03-12", status = "01", fac = "F3"))   # next day
  st <- build_stays(cl)
  expect_equal(nrow(st), 1L)
  expect_equal(st$admit_date, d("2025-03-01"))
  expect_equal(st$discharge_date, d("2025-03-12"))
  expect_equal(st$discharge_status, "01")       # from the closing claim
  expect_equal(st$first_facility, "F1")
  expect_equal(st$final_facility, "F3")
  expect_equal(st$n_claims, 3L)
})

test_that("a two-day gap starts a new stay", {
  cl <- rbind(claim("A", "2025-03-01", "2025-03-05"),
              claim("A", "2025-03-07", "2025-03-09"))
  expect_equal(nrow(build_stays(cl)), 2L)
})

test_that("an interim bill nested inside a longer claim does not split the stay", {
  cl <- rbind(claim("A", "2025-03-01", "2025-03-20"),
              claim("A", "2025-03-03", "2025-03-08", fac = "F2"),
              claim("A", "2025-03-19", "2025-03-25", fac = "F3"))
  st <- build_stays(cl)
  expect_equal(nrow(st), 1L)
  expect_equal(st$discharge_date, d("2025-03-25"))
})

test_that("maternity is detected on any claim in the chain; planned uses principal dx", {
  cl <- rbind(claim("A", "2025-03-01", "2025-03-03", dx = "O80", status = "02"),
              claim("A", "2025-03-03", "2025-03-05", dx = "I50.9"),
              claim("B", "2025-04-01", "2025-04-02", dx = "Z51.11"))
  st <- build_stays(cl)
  expect_true(st[member_id == "A", is_maternity])
  expect_true(st[member_id == "B", is_planned])
  expect_false(st[member_id == "A", is_planned])
})
