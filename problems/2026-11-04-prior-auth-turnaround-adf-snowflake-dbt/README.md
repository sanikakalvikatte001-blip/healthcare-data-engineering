# Prior authorization turnaround: ADF → Snowflake → dbt

**Tech:** dbt (SQL, Snowflake + DuckDB targets), Snowflake SQL, Azure Data Factory (pipeline JSON), with Python only for synthetic data, a local load emulator and static checks.

**Area:** Utilization management / prior authorization / incremental ELT

## Problem

A health plan's utilization-management (UM) platform records every prior authorization (PA) request and its status history: received, pended for clinical info, info received, approved, denied, partially approved, withdrawn. Leadership needs to know:

- how long determinations take,
- whether they are made within the required timeframe,
- which open requests are about to go overdue.

Getting that number right from an operational source is harder than it looks:

- The source is extracted **incrementally** on a `modified_at` watermark, with a **1-hour overlap**, so the same row lands twice.
- Status events are **keyed late** (back-dated entries days after the fact).
- A decision is sometimes **keyed wrong and corrected** later under the same `event_id`.
- Requests are **reclassified** after intake, e.g. expedited downgraded to standard.
- Open requests get their decision in a **later load**. An incremental model that only looks at new *request* rows never updates them.

## Why it matters

- The CMS Interoperability and Prior Authorization final rule (**CMS-0057-F**) requires impacted payers to decide **expedited requests within 72 hours and standard requests within 7 calendar days** starting in 2026. It also requires them to **publicly report** PA metrics, including % approved, % denied and average/median time to decision.
- Late determinations delay patient care and create provider abrasion and compliance exposure.
- UM operations needs a daily work queue of requests at risk of breaching the timeframe.

## Architecture

```
 Azure SQL (UM platform)                     ADLS Gen2 landing                 Snowflake
 um.pa_request ─┐                            landing/um/<table>/               RAW.UM.PA_REQUEST
 um.pa_status_  ├─ ADF pl_um_incremental ──▶  load_date=…/run_id=…/ ── COPY ──▶ RAW.UM.PA_STATUS_EVENT
 event          ┘   (watermark + overlap,     *.parquet                 INTO   RAW.CONTROL.WATERMARK
                     daily trigger)                                                │
                          │ on success: start Container Apps job ─▶ dbt build --target snowflake
                          │ on failure/skip: alert webhook                          ▼
                                                     ANALYTICS.STAGING ▶ INTERMEDIATE ▶ MARTS (+ SNAPSHOTS)
```

| Folder | What's in it |
|---|---|
| `adf/` | ADF git-mode definitions: Key Vault, Azure SQL, ADLS and SnowflakeV2 (key-pair) linked services; parameterized datasets; `pl_um_incremental_to_snowflake`; daily schedule trigger |
| `snowflake/` | Roles, warehouses and service users; storage integration and external stage; RAW and watermark tables; the `COPY INTO` + watermark statements ADF runs; COPY_HISTORY audit |
| `dbt/` | dbt project with `local` (DuckDB) and `snowflake` targets |
| `scripts/` | `generate_um_extracts.py` (synthetic source and extract files), `local_adf_emulator.py` (stands in for ADF Copy and COPY INTO, including load-history skip) |
| `tests/` | pytest static checks for the ADF JSON and the Snowflake SQL |

### dbt models

```
sources (RAW.UM, freshness on _loaded_at)
 └─ staging/      stg_um__pa_requests, stg_um__pa_status_events   latest version per key, typed
     ├─ snapshots/ snap_pa_request                                  SCD2 (timestamp strategy on source modified_at)
     └─ intermediate/ int_pa_status_events_sequenced                 event order, pend durations
                      int_pa_request_lifecycle                       first determination, turnaround, timeframe
         └─ marts/  fct_prior_auth_request      incremental (MERGE on Snowflake, delete+insert on DuckDB)
                    mart_pa_turnaround_monthly  CMS-0057-F style metrics by month x LOB x priority
                    mart_pa_open_overdue        view: open requests aged at query time -> OVERDUE / AT_RISK / ON_TRACK
```

### Key design decisions

| Decision | Why |
|---|---|
| RAW is **append-only, all text** and carries `_file_name` / `_loaded_at` | COPY never fails on a type drift, and every row can be traced to its file. Staging casts the types and keeps the latest version per key. |
| Watermark advances **in the same Script activity, after COPY succeeds** | A failed COPY leaves the old watermark, so the next run re-extracts and nothing is skipped. |
| 1-hour **overlap** on each extract, dedup in staging | Catches rows from transactions still in flight at the cutoff. The duplicates this creates are expected and handled. |
| Incremental fact keyed on **`last_loaded_at = greatest(request, any event)`** | A request decided days after it was received is re-processed when its *event* arrives, not only when its header changes. The negative check below shows why. |
| Turnaround is **calendar hours from receipt to the first determination**; pend time is reported but **not subtracted** | Matches a calendar-day regulatory clock. Timeframes are dbt `vars`, so a plan can apply its own state or contract rules. |
| Open-request aging is a **view** | Aging stored in the incremental fact would go stale for requests that don't change. |
| Snapshot uses the **source `modified_at`** | `dbt_valid_from` is when the UM nurse reclassified the request, not when dbt ran. |
| `generate_schema_name` override | Gives clean `ANALYTICS.STAGING` / `ANALYTICS.MARTS` schemas in Snowflake. |
| No dbt packages | The generic `expression_is_true` test and the relation-compare macro are in `macros/` and `tests/generic/`, so CI needs no network for `dbt deps`. |

## How to run

```bash
pip install -r requirements.txt
./run_local.sh
```

`run_local.sh` does the following:

1. Generates the synthetic UM data. Batch 0 is the history through 2026-10-15, followed by 17 daily batches through 2026-11-01.
2. For each batch, runs the emulated ADF/COPY load and then `dbt build`, which covers models, snapshot, data tests and unit tests.
3. Re-loads the last batch. COPY load history skips it, so this is a no-op.
4. Clones the incremental fact, runs a `--full-refresh` of it, and asserts the two are identical with `dbt run-operation assert_relations_equal`.
5. Exports the marts to `output/` and runs the pytest static checks.

Against Snowflake:

1. Run `snowflake/00`–`02` once.
2. Publish `adf/` from the ADF git repo.
3. Set `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER` and `SNOWFLAKE_PRIVATE_KEY_PATH` for the dbt job and run `dbt build --target snowflake`.

**What was and wasn't executed:**

- **Executed here:** the dbt project, end to end on DuckDB, and `dbt parse --target snowflake` (with `dbt-snowflake` installed).
- **Statically checked only:**
  - The ADF JSON: references resolve, dataset parameters are supplied, `dependsOn` names exist, expressions are balanced, and the COPY select lists match the RAW DDL.
  - The Snowflake scripts: they parse with sqlglot's Snowflake dialect, though role, user and integration DDL falls back to generic command parsing.
- **Not run:** ADF and Snowflake themselves, because no Azure or Snowflake account was available.
- **Local vs. production differences:** the local landing files are CSV in `batch=<n>/` folders, while ADF writes parquet in `load_date=/run_id=` folders.

## Results

Synthetic UM data: 1,800 PA requests received 2026-07-01 to 2026-10-31, across Medicaid, Medicare Advantage and Commercial, 5 service categories, and FHIR API / portal / fax channels.

**Loads:** 36 files (2 tables × 18 batches).

| | RAW rows | After staging dedup |
|---|---:|---:|
| Requests | 1,812 | 1,800 |
| Status events | 4,498 | 4,464 |

The difference is overlap duplicates plus later versions. Seven decisions were corrected across loads (DENIED → APPROVED under the same `event_id`), and the corrected version wins. 203 events were keyed more than 2 days after they happened. 58 requests received before the initial load were updated by later daily loads.

**Snapshot:** three expedited requests were downgraded to standard after intake. Each got its own SCD2 history, with `dbt_valid_from` taken from the source:

| request_id | priority | dbt_valid_from | dbt_valid_to |
|---|---|---|---|
| PA000580 | EXPEDITED | 2026-10-12 07:24:47 | 2026-10-15 04:23:09 |
| PA000580 | STANDARD | 2026-10-15 04:23:09 | |
| PA001375 | EXPEDITED | 2026-10-12 01:07:13 | 2026-10-16 13:47:55 |
| PA001375 | STANDARD | 2026-10-16 13:47:55 | |
| PA000631 | EXPEDITED | 2026-10-16 04:19:01 | 2026-10-20 09:59:07 |
| PA000631 | STANDARD | 2026-10-20 09:59:07 | |

**Request status:** 1,692 determined, 52 withdrawn, 56 still open on 2026-11-01. 464 requests were pended for info, with a median pend of 50.3 h.

| priority | determinations | % approved | % denied | median h | avg h | p90 h | timeframe h | within timeframe | late |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| EXPEDITED | 286 | 81.1 | 12.9 | 33.6 | 48.6 | 105.8 | 72 | **77.3%** | 65 |
| STANDARD | 1,406 | 79.6 | 16.4 | 84.6 | 100.3 | 183.8 | 168 | **85.6%** | 203 |

The expedited p90 of 106 h is well past the 72 h requirement. Expedited compliance falls from 86.4% (July) to 75.0% (Aug–Sep) and 73.7% (Oct), which is the trend the monthly mart is built to show. Pended requests account for 166 of the 268 late determinations: 61.8% of pended requests are decided within the timeframe, compared with 91.9% of the rest.

**Open work queue** (`mart_pa_open_overdue`, as of 2026-11-01): 6 OVERDUE, 6 AT_RISK (more than 75% of the timeframe used) and 44 ON_TRACK.

**Tests:** all pass on every one of the 18 batch runs.

- `dbt build`: 38 nodes.
  - 27 data tests: unique, not null, accepted values, relationships (warn), `expression_is_true`, and 2 singular tests (snapshot current = staging, monthly mart reconciles to the fact).
  - 3 unit tests: pend/turnaround hours, first determination wins / open stays open, and corrected event replaces the original.
- pytest: 27 static checks.
- Incremental vs. full refresh: 1,800 = 1,800 rows, 0 differences across 22 columns.

**Negative check:** if the incremental filter uses only the request header's `_loaded_at` (the common shortcut), the full-refresh comparison fails with **275 stale rows**. Those are requests whose decision arrived in a later load but never updated in the fact.

Exported marts are in `output/`. All data is synthetic: member IDs and NPIs are made up, and there is no PHI.
