# Run all tests from the project folder:  Rscript tests/testthat.R
library(testthat)
test_dir("tests/testthat", reporter = "summary", stop_on_failure = TRUE)
