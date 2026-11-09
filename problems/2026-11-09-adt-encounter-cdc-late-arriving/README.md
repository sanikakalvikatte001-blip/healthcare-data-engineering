# Incremental ADT encounter load with late-arriving, out-of-order and duplicate messages

**Tech:** SQL (PostgreSQL 16, PL/pgSQL procedures, `MERGE`, SCD Type 2) · **Area:** HL7 v2 ADT / Incremental (CDC) loads / Encounters

## Problem

A hospital interface engine drops HL7 v2 ADT messages (A01 admit, A04 register, A02 transfer, A08 update, A03 discharge, A11 cancel admit, A13 cancel discharge) into a landing table once a day. The warehouse needs one current row per encounter, loaded incrementally. Real feeds don't arrive cleanly:

- **Late and out-of-order messages.** After queue backlogs, downtime replays or interface restarts, messages arrive hours or days after the event. An A03 can land before its A01, or a stale A02 can land after a newer one.
- **Redeliveries.** The engine re-sends a message with the same MSH-10 control id when it doesn't get an ACK.
- **Resends.** Someone in the EHR manually re-sends a message. It gets a new control id, but the content is identical.
- **Re-dropped files.** A vendor delivers the same daily file twice.
- **Junk.** Messages with no visit number (PV1-19), patient-level events (A28/A31) in the encounter feed, a discharge time before the admit time, or sender clock skew.

The usual approach, an upsert keyed on visit number where the last message received wins, quietly publishes the wrong census. A late A01 flips a cancelled visit back to ADMITTED, and a stale transfer moves the patient back to a unit they already left.

## Why it matters

The encounter table feeds the daily census, bed management, length-of-stay, readmission logic, quality measures and the encounters that get attached to claims. When the status or location is wrong, the error doesn't show up as a failed load. It shows up as a census that's off by a few patients and nobody can explain. You also need to be able to say what the warehouse showed on a given day, because yesterday's census report was built from it.

## Approach

```
landing.adt_event ──► etl.load_adt_batch(batch_id)                      ┌► core.encounter          (current state, MERGE)
 (append-only)         1 pick up undispositioned rows                    │
                       2 quarantine (4 rules)       ─► etl.event_disposition (1 row per landing row)
                       3 dedup: MSH-10, then content hash
                       4 append to core.encounter_event (immutable, flags late arrivals)
                       5 re-fold touched encounters in EVENT-TIME order ┤
                       6 SCD2 publish + MERGE                            └► core.encounter_history (SCD2 by batch)
                       7 scorecard ─► etl.batch_log (one row per run)
```

Key decisions:

1. **The event log is the source of truth, and state is derived from it.** Every unique message goes into `core.encounter_event` once. Two unique keys back this up: `(source_system, msg_control_id)` and `content_hash`, which is an md5 of the business content without the transport metadata.
2. **Replay in event time.** `core.fold_encounter()` is a procedural PL/pgSQL fold over one encounter's events, ordered by `EVN-2` event time. Receive time is only a tie-breaker. Each message carries the full PV1 snapshot as of its own event time, and the trigger event drives the status machine (A13 reopens and clears the discharge, A11 cancels). A late message lands where it actually happened in the sequence. Because of that, the final state doesn't depend on arrival order.
3. **Only re-fold what changed.** Each batch re-folds just the encounters it touched. Each fold is a small indexed scan, so a daily run stays cheap.
4. **Late is measured against what was published.** An event is flagged `is_late` (with `late_by`) only if it's older than the last event already published for that encounter, meaning downstream users saw a state that was missing it. A delayed message for an encounter that hadn't been loaded yet is not late.
5. **Idempotent by design.** A batch processes only landing rows that have no disposition yet. So re-running a batch is a no-op, and a re-dropped file comes back as all duplicates. Every run gets its own row in `etl.batch_log`, so the history of runs is never overwritten.
6. **SCD2 keyed by batch.** A new version is written only when the published state hash changes. Each version is tagged `NEW`, `IN_ORDER` or `LATE_CORRECTION`, so you can see which census days were wrong and later corrected.
7. **Failure isolation.** Each batch runs in a PL/pgSQL exception block. If it fails, its work is rolled back, the run is logged `FAILED` with the error, and its rows stay undispositioned so a retry picks them up. `etl.load_pending_batches()` commits after each batch and stops at the first failure.

Synthetic data is generated in SQL with md5-seeded randomness, so every run produces the same data. The generator writes the **ground truth** (`synthetic.expected_state`) directly from the encounter plan using plain `CASE` logic. It never replays events, so the reconciliation doesn't depend on the fold being tested.

## Layout

```
sql/ddl/01_schemas_and_tables.sql      landing / etl / core schemas
sql/procs/02_fold_encounter.sql        event-time fold (PL/pgSQL)
sql/procs/03_load_adt_batch.sql        batch procedure + load_pending_batches()
sql/synthetic/10_generate_adt_feed.sql deterministic feed + ground truth (no PHI)
sql/reports/20_load_report.sql         scorecard, late arrivals, reconciliation, naive counterfactual
tests/00_assert_helpers.sql            assert_eq / assert_true, scenario fixtures
tests/10_test_scenarios.sql            49 hand-built scenario assertions
tests/20_test_end_to_end.sql           14 assertions on the full synthetic feed
scripts/run_demo.sh, run_tests.sh
docker-compose.yml                     PostgreSQL 16
```

## How to run

You need PostgreSQL 15+ (for `MERGE`) and `psql`/`createdb` on PATH. The scripts use the standard `PG*` environment variables.

```bash
# optional: docker compose up -d && export PGHOST=localhost PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres
./scripts/run_demo.sh          # build, generate 600 encounters, load 5 daily batches, re-drop one file, report
./scripts/run_tests.sh         # scenario tests + end-to-end reconciliation
N_ENCOUNTERS=5000 ./scripts/run_demo.sh   # bigger feed
```

## Results

These are from the actual run below (600 synthetic encounters, events 2026-11-01 to 2026-11-03, delivered across five daily batches). The 2026-11-02 file was dropped a second time.

**Batch scorecard (`etl.batch_log`)**

| batch | run | landed | quarantined | dup MSH-10 | dup content | applied | late | enc new | enc changed | enc same |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-01 | 1 | 461 | 2 | 7 | 6 | 446 | 0 | 290 | 0 | 0 |
| 2026-11-02 | 1 | 594 | 3 | 23 | 11 | 557 | 4 | 293 | 74 | 6 |
| 2026-11-02 | 2 (re-drop) | 594 | 3 | 580 | 11 | **0** | 0 | 0 | 0 | 0 |
| 2026-11-03 | 1 | 209 | 3 | 23 | 5 | 178 | 16 | 11 | 135 | 13 |
| 2026-11-04 | 1 | 39 | 0 | 7 | 0 | 32 | 11 | 5 | 16 | 11 |
| 2026-11-05 | 1 | 10 | 0 | 2 | 0 | 8 | 0 | 1 | 7 | 0 |

- **1,907** landing rows, each with exactly one disposition: 1,221 applied (one per true event), 642 duplicate by MSH-10 (62 redeliveries + 580 from the re-dropped file), 33 duplicate by content (22 EHR resends + 11 from the re-drop), and 11 quarantined (8 seeded junk rows + 3 re-dropped).
- **82** of the 1,221 true events (6.7%) arrived more than 24h late. **31** applied events were flagged late, meaning they were older than state already published for their encounter. A01 and A04 were the most common (24), up to 29.2h behind (an A02 transfer).
- SCD2 history: 600 `NEW`, 229 `IN_ORDER`, 3 `LATE_CORRECTION` versions. Most late events didn't change state, because the fold puts them behind newer snapshots instead of letting them overwrite those snapshots.
- Final census: 345 admitted, 241 discharged, 14 cancelled.
- **Reconciliation against ground truth: 600 / 600 encounters loaded, 0 mismatches.**
- **Counterfactual:** a naive "last message received wins" upsert over the *same de-duplicated events* gets **24 of 600 encounters (4%) wrong**: 9 wrong status, 10 wrong location, 8 wrong attending.

**Tests:** `./scripts/run_tests.sh` passes all **63 assertions**: 49 scenario assertions and 14 end-to-end. The scenarios cover:

- discharge before admit
- a stale transfer
- a cancel that arrives before its admit
- A13 reopening an encounter
- a late discharge that keeps a newer attending
- in-batch, cross-batch and new-MSH-10 duplicates
- each quarantine rule
- file re-drop idempotency (byte-identical `core.encounter`)
- SCD2 contiguity
- the failed-batch / retry path

The end-to-end checks include a full re-fold of the log that reproduces the stored state.
