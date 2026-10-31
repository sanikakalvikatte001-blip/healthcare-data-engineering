# Run all tests:  Rscript tests/testthat.R   (from the project folder)
library(testthat)
test_dir("tests/testthat", reporter = "summary", stop_on_failure = TRUE)
