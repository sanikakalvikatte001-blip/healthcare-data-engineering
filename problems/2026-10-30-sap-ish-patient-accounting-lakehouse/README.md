# SAP IS-H Patient Accounting → Lakehouse, Reconciled to 837 Claims

A PySpark medallion pipeline (bronze → silver → gold) that takes SAP IS-H patient accounting extracts and builds encounter and charge facts. It then reconciles every SAP charge against the 837P claim lines that went out the door. It is packaged as a wheel with a Databricks Asset Bundle (Unity Catalog + Delta), and runs and is tested locally with `local[*]`.

## Problem

Many hospitals run patient administration and billing in **SAP IS-H** (patient management). Case, movement and service postings live in SAP tables like `NFAL`, `NBEW` and `NLEI`, while claims are produced and tracked in other systems. When this data is moved into a lakehouse, the same problems show up again and again:

- **ODP / SLT change logs, not tables.** Extracts arrive as create/update/delete records (`ODQ_CHANGEMODE`) across full and delta loads. Loading them as-is double-counts charges and keeps deleted cases.
- **SAP data types.** `00000000` means "no date", times are `HHMMSS`, quantities come as `"   2.000"`, negatives use a trailing minus (`125.00-`), and flags are `'X'`.
- **ALPHA conversion.** SAP stores case `0004000123`, but the claim's CLM01 says `4000123`. A naive join matches **0** of 4,127 claim lines.
- **Client (MANDT) mixing.** Test-client 200 rows reuse production case numbers.
- **Storno (cancellation) postings.** SAP corrects a charge by cancelling it (`STORN = 'X'`) and re-posting it under a new document number. Cases can be cancelled too, which cancels all of their charges.
- **Charges change after billing.** Late charges, quantity corrections and cancellations happen after the claim went out, so SAP and the claim no longer agree.

## Why it matters

- **Revenue leakage:** a charge posted in SAP but never billed is lost money. Most of it is late charges.
- **Compliance:** billing a cancelled service, or a service with no charge behind it, is an overbilling risk. It needs a corrected claim (frequency code 7) or a void (code 8).
- **Migration:** IS-H data has to be moved and validated when hospitals modernize their platforms. This is the core pattern for that work: land SAP faithfully, apply changes correctly, and prove the numbers tie out to downstream billing.

## Approach

```
landing (CSV extracts)          bronze (append-only)      silver (current state)        gold
──────────────────────          ────────────────────      ──────────────────────        ────
sap_ish/NPAT  full+delta  ──►   ish_npat      ──┐         ish_patient                   fact_encounter
sap_ish/NFAL  full+delta  ──►   ish_nfal        │  MANDT  ish_case                      fact_charge
sap_ish/NBEW  full+delta  ──►   ish_nbew        ├─ filter ish_movement        ──►       recon_charge_vs_claim
sap_ish/NLEI  full+delta  ──►   ish_nlei        │  + ODP  ish_service                   revenue_integrity_summary
sap_ish/NTPK  full        ──►   ish_ntpk        │  apply  ish_service_catalog
claims_837    lines       ──►   claim_837_line ─┘  + SAP  claim_837_line
                                 + _source_file      types
                                 + _ingested_at
```

**Bronze** ([bronze.py](src/sap_lakehouse/bronze.py)): all columns stay strings, exactly as delivered, plus lineage columns (`_source_file` from `_metadata.file_path`, `_ingested_at`). Files are ingested once: a re-run skips files already in bronze, so it is idempotent.

**Silver** ([cdc.py](src/sap_lakehouse/cdc.py), [sap_types.py](src/sap_lakehouse/sap_types.py), [silver.py](src/sap_lakehouse/silver.py)):

1. Keep production client `MANDT = 100` only.
2. `apply_changes()` keeps the latest change per key, ordered by `ODQ_TSN` then `ODQ_RECNO` (numerically), and drops keys whose latest change is `D`. This is the same contract as `APPLY CHANGES` in Databricks declarative pipelines. Because silver is rebuilt from the full change log, re-delivered or out-of-order files give the same answer.
3. SAP type functions: `sap_date` (uses `try_to_timestamp`, so `00000000` and impossible dates become NULL instead of failing under ANSI mode), `sap_timestamp`, `sap_number` (padding, thousands separators, trailing minus), `alpha_in` / `alpha_out`, `sap_flag`.
4. SAP field names become business names (`FALNR` → `case_id`, `IBGDT` → `service_date`). The SAP name is kept in a comment next to each column.

**Gold** ([gold.py](src/sap_lakehouse/gold.py)):

- `fact_encounter`: one row per case. Admit and discharge timestamps come from movements (`min_by` / `max_by` for the admitting and discharging department), plus length of stay, age at admission, open/cancelled flags, and whether the case was in the billing run's scope.
- `fact_charge`: one row per SAP posting, priced from the service master. A **case-level cancellation cascades** to all of its charges. The SAP service → CPT crosswalk comes from a customer field (`ZZCPT`), which is how many SAP sites do it.
- `recon_charge_vs_claim`: full outer join of SAP and 837 at **(case, CPT, service date)**, after aggregating active quantity and amount on each side. Aggregating first matters: a storno + re-post is one units change, not a "cancelled but billed" plus a "not billed".

| Status | Meaning | Action |
|---|---|---|
| `NOT_BILLED` | active SAP charge, no claim line | late charge → corrected claim |
| `CANCELLED_BUT_BILLED` | all SAP postings cancelled, still on the claim | corrected claim / void |
| `BILLED_NOT_IN_SAP` | claim line with no SAP charge | billing compliance review |
| `UNITS_MISMATCH` | quantities differ | corrected claim |
| `AMOUNT_MISMATCH` | same units, different dollars | check the price list / charge master |
| `MATCHED` / `CANCELLED_NOT_BILLED` | consistent | none |

- `revenue_integrity_summary`: rows and dollars by department and status.

**Environments** ([config.py](src/sap_lakehouse/config.py), [conf/](src/sap_lakehouse/conf/)): the same code writes `hc_dev.<layer>.<table>` **Delta** tables on Databricks, or `<layer>.<table>` **Parquet** tables in a local Hive metastore. [databricks.yml](databricks.yml) builds the wheel and deploys a 3-task job (bronze → silver → gold). [notebooks/sap_ish_revenue_integrity.py](notebooks/sap_ish_revenue_integrity.py) is the analyst view in Databricks.

**Synthetic data** ([tools/generate_synthetic_extracts.py](tools/generate_synthetic_extracts.py), a plain-Python helper): 400 patients and 600 cases (239 inpatient, 361 outpatient), September–October 2026. There is a full extract on 2026-10-26 and a delta on 2026-10-28, plus one 837 billing-run file. Defects are planted on purpose and their counts are written to `data/planted_defects.json`, which the tests assert against. No real PHI.

## How to run

Needs Python 3.10+ and Java 17+ (tested with PySpark 3.5.3, Java 21).

```bash
pip install -r requirements.txt
python tools/generate_synthetic_extracts.py             # (re)writes data/landing/*  (already committed)
PYTHONPATH=src python -m sap_lakehouse.pipeline --layer all --conf local
python -m pytest -q                                      # 17 tests
```

On Databricks (Unity Catalog), with the Databricks CLI:

```bash
databricks bundle deploy -t dev
databricks bundle run sap_ish_lakehouse -t dev
```

> **Note:** The pipeline and tests were run locally with Parquet tables. The Delta Lake jars could not be downloaded in the build environment. The Databricks bundle builds the same wheel and switches the table format to Delta through `conf/databricks.json`, but it has not been deployed to a workspace yet.

## Results

Local run, `local[*]`:

```
[bronze] ish_npat=410, ish_nfal=615, ish_nbew=833, ish_nlei=4,384, ish_ntpk=15, claim_837_line=4,127
[silver] ish_patient=400, ish_case=600, ish_movement=833, ish_service=4,367, ish_service_catalog=15, claim_837_line=4,127
[gold]   fact_encounter=600, fact_charge=4,367, recon_charge_vs_claim=4,140, revenue_integrity_summary=23
```

Bronze → silver: 615 case change rows become 600 current cases. That excludes 5 test-client rows, 1 case deleted in SAP, and 9 delta updates (7 discharges and 1 case cancellation applied to existing keys, plus the delete). A second run adds **0** bronze rows and gives identical silver/gold counts.

**Reconciliation, SAP charges vs 837 claim lines:** every planted defect was found.

| Status | Keys | SAP amount | Claim amount | Variance |
|---|---:|---:|---:|---:|
| NOT_BILLED | 13 | 764.00 | 0.00 | −764.00 |
| CANCELLED_BUT_BILLED | 6 | 0.00 | 497.00 | +497.00 |
| BILLED_NOT_IN_SAP | 4 | 0.00 | 1,840.00 | +1,840.00 |
| UNITS_MISMATCH | 5 | 436.00 | 218.00 | −218.00 |
| AMOUNT_MISMATCH | 4 | 288.00 | 316.80 | +28.80 |
| MATCHED | 4,108 | 1,800,281.00 | 1,800,281.00 | 0.00 |

- All 4,127 claim lines are accounted for: 4,108 matched + 19 exceptions.
- The 13 not-billed keys are 6 charges dropped from the claim + 7 late charges posted after the billing run.
- The 6 cancelled-but-billed keys are 3 cancelled services + the 3 charges of 1 cancelled case.
- The 5 units mismatches are 2 in-place quantity updates (one updated twice in the same delta; the later record wins) + 3 storno-and-repost corrections.
- Overbilling exposure (claims above SAP) is $2,365.80, and leakage (SAP above claims) is $982.00. Outpatient clinic (MEDC) has 3 cancelled-but-billed keys, all from the one cancelled case.

**Encounters:** 239 inpatient stays with an average length of stay of 3.94 days, 6 still open, and 361 outpatient visits.

**Tests (17 passing):** SAP type conversions (dates, timestamps, ALPHA, signed numbers, flags); ODP change-log rules (create/update/delete, TSN/RECNO ordering, numeric RECNO, re-delivery, re-create after delete, client isolation); and end-to-end checks (exact defect counts against `planted_defects.json`, test-client and deleted-case exclusion, cancellation cascade, storno-repost classification, latest-update-wins, the ALPHA join, encounter facts, and bronze idempotency).
