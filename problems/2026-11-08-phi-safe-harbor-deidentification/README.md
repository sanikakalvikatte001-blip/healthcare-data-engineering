# PHI de-identification (HIPAA Safe Harbor) with a fail-closed policy and a release gate

A small, **config-driven** Python library + CLI built on **polars**. It turns an EHR extract (patients + encounters with clinician notes) into a research/analytics dataset that meets the HIPAA **Safe Harbor** method (45 CFR 164.514(b)(2)). It refuses to release anything if a column has no rule or if any PHI is still found in the output.

## Problem

Analytics, research and vendor teams ask for "a de-identified copy" of clinical data all the time. In practice it's usually a one-off SQL script that drops a few obvious columns. That breaks in predictable ways:

- **New columns leak.** The source system adds `guarantor_phone` or `emergency_contact`, and the `SELECT *` extract quietly ships it.
- **Free text is ignored.** Notes say *"Pt Chen, Wei … call back at (614) 555-0123 … seen 03/14/2026 … MRN100231"*. Structured columns are clean, notes are not.
- **The edge rules are missed.** Safe Harbor is more than "remove name and SSN":
  - **Dates:** all date elements except the year must go. That means admit and discharge dates too, not only the DOB.
  - **Ages over 89** must be grouped as 90+. That includes any year that reveals the age, so the birth year of a 95-year-old must go too.
  - **ZIP codes:** only the first 3 digits may be kept, and only if that 3-digit area has more than 20,000 people. Otherwise it must be `000`.
- **"Pseudonymization" by hashing the MRN.** A re-identification code is allowed only if it isn't derived from the identifier (164.514(c)). `sha256(MRN)` can be reversed by brute force over the MRN range.
- **Nobody checks the output.** There's no proof the released file is clean, only that the script ran.

## Why it matters

- **Compliance:** a release with PHI in it is a breach. Breach notification, OCR investigation and contract penalties all follow.
- **Data access speed:** when de-identification is repeatable and auditable, a privacy officer can approve a pipeline once, instead of reviewing every extract by hand.
- **Analytic value:** keeping `patient_key` joins, ages, years, state and ZIP3 keeps the data useful for utilization, quality and population-health work.

## Approach

```
data/*.csv ─► policy coverage check ─► surrogate keys ─► column rules (polars exprs) ─► note scrubbing ─► release gate ─┬─► output/release/*.csv
             (fail closed: every         (random, shared      year / zip3 / dob_to_age      patterns +         checks       ├─► output/restricted/crosswalk_*.csv
              column needs a rule)        across tables)       drop / keep                  known values                    └─► output/deid_report.json (always)
```

| File | Responsibility |
|---|---|
| `config/deid_policy.toml` | The policy: a rule for **every** column of every table, the reference date, the restricted ZIP3 list, and which patient fields to use when scrubbing notes. Each rule is commented with the Safe Harbor identifier letter it covers. |
| `src/safeharbor/policy.py` | Loads and validates the policy. `check_coverage` stops the run on any column without a rule. It also refuses any identifier-like column name (`*_ssn`, `home_phone`, `mrn` …) marked `keep`. |
| `src/safeharbor/transforms.py` | polars expressions: `to_year`, `to_zip3` (ZIP+4, malformed and restricted → `000`), `dob_to_age` (birthday-correct age, top-coded at 90, birth year nulled for 90+). Also `SurrogateRegistry`: random tokens from the OS CSPRNG, consistent across tables so `patient_key` still joins. |
| `src/safeharbor/text_scrub.py` | Note redaction in two passes. (1) Format detectors: URL, e-mail, SSN, phone, dates (3 formats), MRN, IP, street address. (2) The patient's **own** known values: name, MRN, SSN, phone, e-mail, street, city. These catch names, which no regex finds reliably. |
| `src/safeharbor/verify.py` | Release gate. Removed columns are absent. No PHI pattern remains in any string cell. No cell equals an original identifier value. No note still contains its patient's identifiers. ZIP3 and age rules hold. Small quasi-identifier cells are flagged as a **warning**. |
| `src/safeharbor/pipeline.py` | Orchestration. Writes `deid_report.json` every run, but writes `release/` and `restricted/` **only if every check passes**, and clears any stale release first. |
| `scripts/generate_synthetic_data.py` | Seeded synthetic extract: 9xx SSNs, 555-01xx phones, `example.org` e-mails. Some patients are 90+, some live in restricted ZIP3 areas, and notes have PHI written inline. |

Key decisions:

- **Fail closed, not fail open.** The policy is an allow-list. An unknown column is an error (exit code `2`), not a pass-through.
- **Two independent layers.** The policy says what *should* happen. The gate checks what *did* happen, using the original identifier values and pattern detectors. A wrong rule is caught by the data, not only by code review (see `test_identifier_hidden_in_innocent_column_blocks_release`).
- **Random surrogates + a restricted crosswalk.** Tokens are not hashes, so they meet 164.514(c). The crosswalk goes to `output/restricted/`, which is git-ignored here and in production is held by the honest broker only. `--seed` exists only for reproducible demos and tests.
- **Renamed columns.** `dob → age_years, birth_year`, `zip → zip3`, `admit_date → admit_year`, `mrn → patient_key`. A consumer can see that a field was transformed without reading the policy.
- **Over-redaction is acceptable, under-redaction is not.** If a patient's last name is also a provider's name, "Dr. Hughes" becomes "Dr. [NAME]" in that patient's notes. That's the right trade-off for a release.
- **All columns read as text.** ZIP `02108` keeps its leading zero, and identifiers are never coerced to numbers.

## How to run

Requires Python 3.11+ (uses `tomllib`).

```bash
cd problems/2026-11-08-phi-safe-harbor-deidentification
pip install -r requirements.txt

python scripts/generate_synthetic_data.py --out data --seed 42      # synthetic extract, no real PHI
PYTHONPATH=src python -m safeharbor --policy config/deid_policy.toml --input data --out output --seed 7
python -m pytest
```

Exit codes: `0` released · `1` blocked by the release gate (no data written) · `2` policy error (e.g. an unmapped column).

## Results

Synthetic extract: **250 patients, 788 encounters**.

```
patients    rows   250 -> 250   columns 13 -> 6
encounters  rows   788 -> 788   columns  8 -> 8
encounters  redactions: ADDRESS=101, DATE=296, EMAIL=114, LOCATION=101, MRN=98, NAME=559, PHONE=181, SSN=96, URL=96
  [PASS] patients.removed_columns_absent: 11 source columns removed/renamed
  [PASS] patients.residual_phi_patterns: 0 pattern hits in string columns
  [PASS] patients.no_original_identifier_values: checked against 2577 original identifier values
  [PASS] patients.zip3_safe_harbor: 15 set to 000; bad_format=0, restricted_left=0
  [PASS] patients.age_top_coded_90: 13 top-coded at 90; over_90=0, birth_year_left_for_90plus=0
  [WARN] patients.small_cells_k5: 228 of 228 (zip3, birth_year, sex) groups have < 5 people (250 of 250 rows)
  [PASS] encounters.removed_columns_absent: 4 source columns removed/renamed
  [PASS] encounters.residual_phi_patterns: 0 pattern hits in string columns
  [PASS] encounters.no_original_identifier_values: checked against 2577 original identifier values
  [PASS] encounters.known_values_scrubbed: 788 notes checked
RELEASED
```

| Metric | Value |
|---|---:|
| Patient columns released | 6 of 13 (`patient_key, age_years, birth_year, sex, state, zip3`) |
| Patients top-coded at age 90 (birth year removed) | 13 |
| ZIPs set to `000` (3-digit areas 059, 692, 893) | 15 (7 + 3 + 5). ZIP3 `788` kept: it looks rural but isn't on the list |
| Notes changed by redaction | 687 of 788. The other 101 had no PHI ("No acute distress …") |
| Redactions in notes | 1,642. 559 of them are names, found through the patient's own record, not regex |
| Patients ↔ encounters join after release | 788 of 788 encounters match a released patient |
| Tests | **42 passed** |

Before → after (one note):

```
Seen by Dr. Hughes. Pt Alvarez, Wei denies chest pain. Fax results to (803) 555-0135.
Seen by Dr. Hughes. Pt [NAME], [NAME] denies chest pain. Fax results to [PHONE].
```

**The warning is the most useful finding.** Every one of the 250 patients is unique on `(zip3, birth_year, sex)`. The release is Safe Harbor compliant, but in a small cohort those three fields still single people out. Safe Harbor also requires no *actual knowledge* that the data could identify someone, so the report surfaces this for the privacy reviewer instead of hiding it. The usual fixes are a coarser birth-year band for small releases, or Expert Determination (164.514(b)(1)) when the use case needs finer detail.

What the tests cover:

- Every detector, and clinical codes that must survive (ICD-10, NPI, BP, doses).
- Birthday-boundary ages, including exactly 89 and exactly 90.
- ZIP+4, restricted and malformed ZIPs.
- Surrogate consistency across tables, and that tokens are not derived from the MRN.
- Policy lint and coverage errors.
- End to end: an MRN copied into an innocent-looking `source_record_ref` column and a phone number in `contact` both **block** the release, and nothing is written.
