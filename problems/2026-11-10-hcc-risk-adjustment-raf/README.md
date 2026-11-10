# CMS-HCC risk adjustment: diagnosis filtering, hierarchies and member RAF scores

**Tech:** PySpark (DataFrame API, `local[*]`), config-driven model tables, small CLI, pytest
**Area:** Risk adjustment (HCC) / Medicare Advantage / Claims & encounter data

## Problem

A Medicare Advantage plan is paid per member, and the payment is scaled by each
member's **risk adjustment factor (RAF)**. The RAF comes from the diagnoses on
the member's claims from the previous year, mapped to **Hierarchical Condition
Categories (HCCs)**.

Getting from raw claims to a RAF you can trust takes more than a join to a mapping table:

- **Not every diagnosis counts.** Lab, radiology and DME claims, procedures that are not
  face-to-face, SNF bills, denied claims and dates of service outside the collection
  year must be filtered out.
- **Claims change.** A replacement claim (frequency 7) supersedes the original; a void
  (frequency 8) cancels the whole claim. Diagnoses from dead versions must not pay.
- **Codes are messy.** `E11.22`, `e1122` and `" E11.22 "` are the same code; `11.9` is not a code.
- **Hierarchies.** Within a disease family only the most severe HCC pays
  (CKD stage 5 trumps stage 4, metastatic cancer trumps breast cancer).
- **The score has several parts:** demographic factor (age as of **Feb 1** of the payment
  year), HCC coefficients, disease interactions (e.g. diabetes + heart failure),
  a payment-HCC count variable, then normalization and the MA coding-intensity adjustment.

## Why it matters

- RAF errors are money errors. An HCC paid from an ineligible source (e.g. a lab claim) is the
  classic RADV audit finding and leads to recoupment; a missed HCC is lost revenue.
- Finance, actuarial and coding teams all need to know **why** a member's score is what it is,
  so every diagnosis line keeps a status and every trumped HCC keeps the HCC that trumped it.
- Model versions (V24 → V28) and payment-year constants change every year, so the rules
  belong in data, not in code.

## Approach

```
model/                     <- everything that changes by model version / payment year
  model_config.json        PY2026 dates, normalization, coding intensity, CPT + specialty
                           filters, bill types, interactions, count variables
  dx_to_hcc.csv            ICD-10-CM -> HCC (V28-style subset, 39 codes)
  hcc_coefficients.csv     HCC coefficients (illustrative)
  hierarchy.csv            parent -> child (transitively closed, validated on load)
  demographic_factors.csv  sex x age band
hcc_raf/
  config.py      typed config + reference tables + fail-fast validation
  filters.py     step 1: claim versions, source eligibility, ICD-10 cleanup -> dx_audit
  hierarchy.py   step 2: member HCCs + set-based hierarchy -> member_hcc
  scoring.py     step 3: demographics, interactions, count variable, RAF -> member_raf
  pipeline.py    wires steps with DataFrame.transform; writes outputs
  __main__.py    CLI: `run` and `explain --member`
scripts/generate_data.py   synthetic members + claims (fixed seed)
```

Key decisions:

1. **One status per diagnosis line, with a fixed precedence**
   (`ORPHAN_DX_NO_HEADER → CLAIM_VOIDED → SUPERSEDED_VERSION → UNKNOWN_MEMBER → CLAIM_DENIED →
   DOS_OUT_OF_WINDOW → INELIGIBLE_PROVIDER_TYPE → INELIGIBLE_SERVICE → INELIGIBLE_BILL_TYPE →
   INVALID_ICD10_FORMAT → NO_HCC_MAPPING → ACCEPTED`). Nothing is silently dropped, so
   `dx_audit` reconciles back to the input row count.
2. **Claim versions with window functions:** the latest `claim_version` wins; if the latest is a
   void, every version of that claim is `CLAIM_VOIDED`.
3. **Source eligibility** follows the CMS encounter-filtering idea: professional claims need a
   face-to-face CPT/HCPCS from an acceptable provider type; facility claims need an inpatient
   bill type (11x), or an outpatient bill type (13x, 71x, 73x, 76x, 77x, 85x) plus a face-to-face CPT.
4. **Hierarchies are one self-join, not recursion.** The hierarchy table is required to be
   transitively closed, and `config.py` refuses to run if it isn't. A gap there (A→B, B→C but
   no A→C) would pay a member for both A and C.
5. **Interactions and count variables are data.** Interactions are exploded to a long table
   (`interaction, group_idx, hcc`); one fires when a member hits every group. Count variables
   are a range join on the number of payment HCCs.
6. **Every enrolled member gets a score**, including members with no claims (demographic only);
   claims for members not enrolled are flagged, not scored.
7. **Age is computed birthday-exact** as of Feb 1 of the payment year (not `months_between/12`,
   which drifts on month-end dates).

> Coefficients and factors are **illustrative**, shaped like the CMS-HCC V28 community,
> non-dual, aged segment. They are not official CMS values. The 5.9% coding-intensity
> adjustment is the statutory minimum; the 1.045 normalization factor is illustrative.
> Out of scope: other segments (dual, institutional, new enrollee, ESRD), MOR/RAPS feeds, and
> the full ICD-10 crosswalk.

## How to run

```bash
pip install -r requirements.txt          # needs Java 17+ for Spark
python scripts/generate_data.py          # writes data/*.csv (405 members)
python -m hcc_raf run                    # writes output/{dx_audit,member_hcc,member_raf}/ and prints a summary
python -m hcc_raf explain --member M9004 # full audit trail for one member
python -m pytest                         # 23 tests
```

## Results

Synthetic input: **405 members, 1,420 claim versions, 2,574 diagnosis lines** (PY2026, DOS 2025).

Diagnosis line status (all 2,574 lines accounted for):

| dx_status | lines |
|---|---:|
| NO_HCC_MAPPING | 879 |
| ACCEPTED | 834 |
| INELIGIBLE_PROVIDER_TYPE | 320 |
| DOS_OUT_OF_WINDOW | 163 |
| SUPERSEDED_VERSION | 101 |
| CLAIM_DENIED | 81 |
| INELIGIBLE_BILL_TYPE | 75 |
| CLAIM_VOIDED | 61 |
| INELIGIBLE_SERVICE | 39 |
| INVALID_ICD10_FORMAT | 19 |
| ORPHAN_DX_NO_HEADER | 1 |
| UNKNOWN_MEMBER | 1 |

Hierarchies: **425 member-HCCs → 400 payment, 25 trumped**.
Interactions triggered: DIABETES_HF 20, HF_KIDNEY 12, HF_CHR_LUNG 10.

| members | members with no HCC | avg raw RAF | avg payment RAF | median payment RAF | max payment RAF |
|---:|---:|---:|---:|---:|---:|
| 405 | 144 | 0.877 | 0.790 | 0.633 | 5.904 |

Most common payment HCCs: 38 (diabetes w/o complications, 73 members), 280 (COPD, 56),
226 (heart failure, 55), 37 (diabetes w/ chronic complications, 45), 155 (major depression, 29).

Hand-calculated scenario members (all verified by tests):

| member | what it tests | raw RAF | payment RAF |
|---|---|---:|---:|
| M9001 | 37 trumps 38, 224 trumps 226, DIABETES_HF interaction | 1.147 | 1.033 |
| M9002 | lab claim, voided claim and 2024 DOS ignored; age 76 exactly on Feb 1 | 0.687 | 0.619 |
| M9003 | inpatient + HOPD bills, 17 trumps 18 and 23, SNF bill ignored, D6 count variable | 6.557 | 5.904 |
| M9004 | replacement claim wins, denied claim, `11.9` rejected, `" j44.9 "` cleaned and accepted | 1.674 | 1.507 |
| M9005 | no claims → demographic only; birthday on Feb 2 keeps age 67 | 0.359 | 0.323 |

`explain` output for M9004 — the replacement claim's I50.84 (HCC 222) pays, the original's I50.9 does not:

```
|claim_id  |claim_version|through_dos|icd10_raw|hcc |dx_status           |
|CLM0000010|1            |2025-04-10 |I50.9    |NULL|SUPERSEDED_VERSION  |
|CLM0000010|2            |2025-04-10 |I50.84   |222 |ACCEPTED            |
|CLM0000011|1            |2025-04-20 |E11.9    |NULL|CLAIM_DENIED        |
|CLM0000012|1            |2025-04-30 |11.9     |NULL|INVALID_ICD10_FORMAT|
|CLM0000012|1            |2025-04-30 | j44.9   |280 |ACCEPTED            |
```

Tests: `23 passed` (filters, versioning, ICD-10 cleanup, hierarchies, age edge cases incl. leap
day, RAF math, reference-data validation, and end-to-end invariants such as "no member is paid
for both a parent and child HCC" and "RAF components add up").
