# Load the package source and provide tiny hand-built fixtures.
suppressPackageStartupMessages(library(data.table))
pkg_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
invisible(lapply(list.files(file.path(pkg_root, "R"), pattern = "\\.R$", full.names = TRUE), source))

d <- as.IDate

# One claim row; defaults describe an ordinary medical stay.
claim <- function(member_id, admit, disch, status = "01", dx = "I50.9",
                  fac = "1900010011", claim_id = NULL, orig = NULL,
                  freq = "1", received = NULL) {
  claim_id <- claim_id %||% paste(member_id, admit, fac, freq, sep = "_")
  data.table(claim_id = claim_id, original_claim_id = orig %||% claim_id,
             freq_code = freq, member_id = member_id, facility_npi = fac,
             admit_date = d(admit), discharge_date = d(disch),
             discharge_status = status, primary_dx = dx,
             received_date = d(received %||% disch) + 10L)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

adult   <- function(ids) data.table(member_id = ids, dob = d("1960-05-15"))
covered <- function(ids) data.table(member_id = ids, eff_date = d("2024-01-01"),
                                    term_date = d("2026-12-31"))

# Full pipeline on a fixture, returning the per-index-stay flags.
run_flags <- function(claims, members = adult(unique(claims$member_id)),
                      enrollment = covered(unique(claims$member_id))) {
  cfg <- readmit_config(2025L)
  st  <- build_stays(current_claim_versions(claims, cfg), cfg)
  fl  <- select_index_stays(st, members, enrollment, cfg)
  flag_readmissions(fl, cfg)
}
