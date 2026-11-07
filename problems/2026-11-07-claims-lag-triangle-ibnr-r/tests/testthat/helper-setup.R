# Loaded automatically by testthat before the test files.
suppressPackageStartupMessages(library(dplyr))

project_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
source(file.path(project_root, "R", "pipeline.R"))
source_lib(project_root)

# Tiny hand-checkable claims set (valuation 2026-03-31, max lag 2):
#   Jan: 100 paid in Jan, 50 in Feb, 10 in Mar  -> cumulative 100, 150, 160
#   Feb: 200 paid in Feb, 80 in Mar             -> cumulative 200, 280
#   Mar:  50 paid in Mar                        -> cumulative  50
toy_claims <- function() {
  tibble::tribble(
    ~claim_line_id, ~claim_id, ~claim_freq_cd, ~claim_type, ~service_date, ~paid_date, ~paid_amount,
    "A-01", "A", "1", "Professional", "2026-01-05", "2026-01-20", 100,
    "B-01", "B", "1", "Professional", "2026-01-10", "2026-02-15",  50,
    "C-01", "C", "1", "Professional", "2026-01-28", "2026-03-02",  10,
    "D-01", "D", "1", "Professional", "2026-02-03", "2026-02-25", 200,
    "E-01", "E", "1", "Professional", "2026-02-14", "2026-03-10",  80,
    "F-01", "F", "1", "Professional", "2026-03-01", "2026-03-30",  50
  ) |>
    mutate(across(c(service_date, paid_date), as.Date))
}
