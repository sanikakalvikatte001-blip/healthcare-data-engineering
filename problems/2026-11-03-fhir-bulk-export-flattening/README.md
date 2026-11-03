# FHIR R4 Bulk Data export (NDJSON) → flat warehouse tables with Spark SQL

## Problem

An EHR or payer hands over a **FHIR Bulk Data `$export`**: one NDJSON file (or several) per resource type, one JSON resource per line. The warehouse and the HEDIS/quality engines downstream need flat tables, not nested JSON. Flattening it naively gets several things wrong:

| What happens in real exports | What goes wrong if you ignore it |
|---|---|
| The same `Patient` appears more than once with different `meta.versionId`, sometimes with the newest version in an **earlier** file | duplicate patients, or the old address/phone wins |
| `name[0]` is a nickname, `identifier[0]` is a member ID, `coding[0]` is a local lab code | wrong name, wrong MRN, no LOINC → lab results invisible to measures |
| References come as `Patient/123` **or** `https://server/R4/Patient/123` | joins silently miss |
| Encounter/Observation points at a Patient that is not in the export | orphan facts with no person behind them |
| `value[x]` is a choice type: `valueQuantity`, `valueCodeableConcept`, `valueString` or `dataAbsentReason` | numeric columns full of NULLs, codes lost |
| A blood-pressure panel (LOINC 85354-9) stores systolic and diastolic as **components** | BP is "missing", so Controlling High Blood Pressure (CBP) looks like a care gap |
| `status = entered-in-error` | retracted results counted as real |
| A truncated line from a killed export job | the whole Spark job fails, or the line silently disappears |

## Why it matters

Bulk FHIR is now the normal way to get clinical data out of EHRs (ONC Cures Act / USCDI) and payer APIs. Quality measures (HbA1c control, CBP), risk adjustment and care-gap reporting all sit on top of these flattened tables. A wrong "latest version", a missed LOINC code or an unexploded BP panel changes measure rates, and a load that cannot prove where every line went will not pass an audit.

## Approach

A thin PySpark driver plus **Spark SQL files that hold all the logic** (the repo is SQL-first; Python only reads files and runs the SQL).

```
fhir_schemas.py          explicit DDL schemas per resource (no schema inference)
flatten_fhir.py          reads NDJSON -> raw_* views, runs sql/*.sql in order, writes Parquet
sql/
  01_patient.sql         newest version per id; official name, MR identifier, phone, birth sex
  02_encounter.sql       newest version; resolve Patient reference; LOS hours (NULL while in-progress)
  03_observation.sql     resolve refs, pick LOINC by system, explode BP components, split value[x]
  04_quarantine.sql      every rejected line/resource with a reason code
  05_load_summary.sql    reconciliation: input = malformed + superseded + quarantined + loaded
  06_latest_measures.sql PIVOT: latest BP / HR / weight / HbA1c per patient
scripts/generate_fhir_export.py   synthetic export generator (planted edge cases)
tests/                   pytest: end-to-end on the export + small hand-built exports per rule
```

Key decisions:

- **Explicit schemas + `PERMISSIVE` mode.** Each choice type (`valueQuantity`, `valueCodeableConcept`, `valueString`) is its own column, so the contract does not change from export to export. Bad lines land in `_corrupt_record` and go to quarantine instead of failing the job.
- **Higher-order functions instead of explode** for repeating elements on Patient: `filter(identifier, i -> exists(i.type.coding, c -> c.code = 'MR'))`, `filter(name, n -> n.use = 'official')`. One patient stays one row. Everything is picked **by meaning (system / type / use), never by position**.
- **Version dedup with `ROW_NUMBER()`** over `versionId DESC, lastUpdated DESC`. File order is not trusted.
- **Reference parsing with one regex** (`(?:^|/)Patient/([^/]+)$`) handles both relative and absolute URLs.
- **`LATERAL VIEW OUTER posexplode(component)`** turns a BP panel into two rows (`component_seq` 1 and 2, `panel_loinc_code = 85354-9`) while single-value observations keep `component_seq = 0`.
- **One reject reason per resource**, first failing rule wins: `ENTERED_IN_ERROR` → `ORPHAN_PATIENT_REF` → `NO_LOINC_CODE`. Malformed lines get `MALFORMED_JSON`.
- **Line-level reconciliation** (`load_summary.balanced`) proves every input line was loaded, superseded, or quarantined — nothing silently dropped.
- Session time zone is **UTC**, so FHIR instants with offsets (`-05:00`) compare correctly.

### Output tables (Parquet in `output/`)

| Table | Grain |
|---|---|
| `patient_flat` | one row per patient (latest version) |
| `encounter_flat` | one row per encounter |
| `observation_flat` | one row per measured value (BP panel = 2 rows) |
| `quarantine` | one row per rejected line/resource, with `reason` and `detail` |
| `load_summary` | one row per resource type, with `balanced` check |
| `patient_latest_measures` | one row per patient, latest vitals/labs pivoted wide |

## How to run

Needs Python 3.10+ and Java 17+.

```bash
cd problems/2026-11-03-fhir-bulk-export-flattening
pip install -r requirements.txt

python scripts/generate_fhir_export.py   # optional: data/export is already committed
python flatten_fhir.py                    # writes output/*.parquet and prints the summary
python -m pytest -q                       # 12 tests
```

## Results

Synthetic export: 40 patients, 3 resource types, 4 NDJSON files, 414 lines.

**Load summary (reconciliation)** — every line accounted for:

| resource_type | input_lines | malformed | superseded | quarantined | loaded_resources | flat_rows | balanced |
|---|---|---|---|---|---|---|---|
| Patient | 46 | 0 | 6 | 0 | 40 | 40 | true |
| Encounter | 78 | 0 | 0 | 1 | 77 | 77 | true |
| Observation | 290 | 1 | 0 | 5 | 284 | 361 | true |

- **Patient:** 46 lines → 40 patients. The 6 superseded lines are 5 older versions plus 1 exact re-export. The patient whose v3 sits in the first file and v2 in the second was loaded as v3.
- **Observation:** 284 resources became 361 rows, because the 77 blood-pressure panels each split into systolic + diastolic rows.

**Quarantine by reason**

| resource_type | reason | count |
|---|---|---|
| Encounter | ORPHAN_PATIENT_REF | 1 |
| Observation | ENTERED_IN_ERROR | 2 |
| Observation | MALFORMED_JSON | 1 |
| Observation | NO_LOINC_CODE | 2 |
| Observation | ORPHAN_PATIENT_REF | 1 |

**Observation rows by `value[x]` type:** Quantity 332, CodeableConcept 27 (SARS-CoV-2 PCR → SNOMED Positive/Negative), string 1 (annotation comment), absent 1 (`dataAbsentReason = not-performed`).

**Encounters:** 55 AMB (avg 1.0 h), 17 EMER (avg 5.8 h), 5 IMP (avg 55.4 h). The one in-progress encounter has `period_end` and LOS = NULL instead of a negative or made-up value.

**Latest-measures mart:** 40 patients, all with a latest BP (systolic > diastolic in every row). 13 have an HbA1c, and 4 of those are > 9 % (the HbA1c "poor control" threshold). 24 have a latest BP ≥ 140/90.

**Tests:** `12 passed` — version ordering across files, official name / MR identifier by meaning, full-URL references, orphans, LOINC by system, BP component explosion, all value[x] types, in-progress encounters, UTC normalisation, malformed lines, and the reconciliation balance.

All data is synthetic, generated by `scripts/generate_fhir_export.py` (fixed seed). No real PHI.
