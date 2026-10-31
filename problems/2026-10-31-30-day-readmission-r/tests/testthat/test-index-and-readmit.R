test_that("age_on is birthday-aware", {
  expect_equal(age_on(d("2007-06-15"), d("2025-06-14")), 17L)
  expect_equal(age_on(d("2007-06-15"), d("2025-06-15")), 18L)
  expect_equal(age_on(d("2008-02-29"), d("2026-02-28")), 17L)
})

test_that("touching enrollment segments merge into one span", {
  en <- data.table(member_id = "A",
                   eff_date  = d(c("2025-01-01", "2025-07-01", "2025-10-01")),
                   term_date = d(c("2025-06-30", "2025-08-31", "2025-12-31")))
  sp <- merge_enrollment_spans(en)
  expect_equal(nrow(sp), 2L)                       # gap Sep 1-30
  expect_equal(sp$term_date[1], d("2025-08-31"))
})

test_that("exclusion waterfall assigns the first failing rule", {
  cl <- rbind(
    claim("OUT",  "2025-12-10", "2025-12-15"),               # after Dec 1
    claim("DIED", "2025-03-01", "2025-03-04", status = "20"),
    claim("XFER", "2025-03-01", "2025-03-04", status = "02"),
    claim("KID",  "2025-03-01", "2025-03-04"),
    claim("MAT",  "2025-03-01", "2025-03-03", dx = "O80"),
    claim("GAP",  "2025-03-01", "2025-03-04"),
    claim("OK",   "2025-03-01", "2025-03-04"))
  ids <- unique(cl$member_id)
  members <- adult(ids); members[member_id == "KID", dob := d("2015-01-01")]
  enroll  <- covered(ids); enroll[member_id == "GAP", term_date := d("2025-03-20")]
  cfg <- readmit_config(2025L)
  fl <- select_index_stays(build_stays(cl), members, enroll, cfg)
  got <- setNames(fl$exclusion_reason, fl$member_id)
  expect_equal(unname(got["OUT"]),  "discharge outside period")
  expect_equal(unname(got["DIED"]), "died during stay")
  expect_equal(unname(got["XFER"]), "transferred out to acute care")
  expect_equal(unname(got["KID"]),  "under 18 at discharge")
  expect_equal(unname(got["MAT"]),  "maternity / perinatal")
  expect_equal(unname(got["GAP"]),  "not enrolled 30 days post-discharge")
  expect_true(is.na(got["OK"]))

  wf <- index_waterfall(fl)
  expect_equal(wf[step == "eligible index stays", stays_remaining], 1L)
  expect_equal(wf[step == "not enrolled 30 days post-discharge", stays_remaining], 1L)
})

test_that("readmission window is day 1 through day 30 after discharge", {
  cl <- rbind(
    claim("A", "2025-02-01", "2025-02-05"),
    claim("A", "2025-03-07", "2025-03-09"),     # day 30 -> counts
    claim("B", "2025-02-01", "2025-02-05"),
    claim("B", "2025-03-08", "2025-03-10"))     # day 31 -> does not
  fl <- run_flags(cl)
  first <- fl[, .SD[1L], by = member_id]
  expect_true(first[member_id == "A", readmitted_30d])
  expect_equal(first[member_id == "A", days_to_readmit], 30L)
  expect_false(first[member_id == "B", readmitted_30d])
})

test_that("a transfer is never counted as a readmission", {
  cl <- rbind(claim("A", "2025-02-01", "2025-02-05", status = "02", fac = "F1"),
              claim("A", "2025-02-05", "2025-02-10", fac = "F2"))
  fl <- run_flags(cl)
  expect_equal(nrow(fl), 1L)
  expect_false(fl$readmitted_30d)
  expect_equal(fl$final_facility, "F2")           # attributed to discharging hospital
})

test_that("planned readmission is skipped but a later unplanned one still counts", {
  cl <- rbind(claim("A", "2025-02-01", "2025-02-05"),
              claim("A", "2025-02-10", "2025-02-11", dx = "Z51.11"),   # planned chemo
              claim("A", "2025-02-20", "2025-02-24", dx = "J18.9"))    # unplanned
  fl <- run_flags(cl)
  first <- fl[stay_id == "A-S01"]
  expect_true(first$readmitted_30d)
  expect_equal(first$readmit_dx, "J18.9")
  expect_equal(first$days_to_readmit, 15L)

  only_planned <- run_flags(cl[1:2])
  expect_false(only_planned[stay_id == "A-S01", readmitted_30d])
  expect_true(only_planned[stay_id == "A-S01", planned_readmit_only])
})

test_that("readmission where the member died still counts; it is not an index stay", {
  cl <- rbind(claim("A", "2025-02-01", "2025-02-05"),
              claim("A", "2025-02-12", "2025-02-15", status = "20"))
  fl <- run_flags(cl)
  expect_equal(nrow(fl), 1L)
  expect_true(fl$readmitted_30d)
})

test_that("a readmission can also be its own index stay", {
  cl <- rbind(claim("A", "2025-02-01", "2025-02-05"),
              claim("A", "2025-02-15", "2025-02-18"),
              claim("A", "2025-03-01", "2025-03-03"))
  fl <- run_flags(cl)
  expect_equal(nrow(fl), 3L)
  expect_equal(fl$readmitted_30d, c(TRUE, TRUE, FALSE))
})

test_that("voided readmission claim does not create a readmission", {
  cl <- rbind(claim("A", "2025-02-01", "2025-02-05"),
              claim("A", "2025-02-12", "2025-02-15", claim_id = "R1"),
              claim("A", "2025-02-12", "2025-02-15", claim_id = "R1V", orig = "R1",
                    freq = "8", received = "2025-04-01"))
  fl <- run_flags(cl)
  expect_equal(nrow(fl), 1L)
  expect_false(fl$readmitted_30d)
})

test_that("rates roll up correctly", {
  flags <- data.table(final_facility = c("F1", "F1", "F1", "F2"),
                      readmitted_30d = c(TRUE, FALSE, FALSE, TRUE),
                      days_to_readmit = c(10L, NA, NA, 4L))
  r <- readmission_rates(flags, by = "final_facility")
  expect_equal(r[final_facility == "F1", readmit_rate_pct], 33.3)
  expect_equal(r[final_facility == "F2", readmit_rate_pct], 100)
  expect_equal(readmission_rates(flags)$readmissions, 2L)
})
