#!/usr/bin/env bash
# Build the schema, generate the synthetic ADT feed, load it batch by batch,
# replay one batch to prove idempotency, and print the report.
#
# Uses standard libpq env vars (PGHOST, PGPORT, PGUSER, PGPASSWORD).
#   DB            database to (re)create          default: adt_cdc
#   N_ENCOUNTERS  synthetic encounters to generate default: 600
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${DB:-adt_cdc}"
N="${N_ENCOUNTERS:-600}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

dropdb --if-exists "$DB"
createdb "$DB"

"${PSQL[@]}" -f sql/ddl/01_schemas_and_tables.sql
"${PSQL[@]}" -f sql/procs/02_fold_encounter.sql
"${PSQL[@]}" -f sql/procs/03_load_adt_batch.sql
"${PSQL[@]}" -v n_encounters="$N" -f sql/synthetic/10_generate_adt_feed.sql

# Incremental load: every daily batch, oldest first, one commit per batch.
"${PSQL[@]}" -c "CALL etl.load_pending_batches();"

# The vendor re-drops the 2026-11-02 file. Same rows land again with new
# landing ids; the load must classify all of them as duplicates.
"${PSQL[@]}" <<'SQL'
INSERT INTO landing.adt_event (batch_id, source_system, msg_control_id, event_type,
       event_ts, received_ts, facility, visit_number, mrn, patient_class, location,
       attending_npi, admit_ts, discharge_ts)
SELECT batch_id, source_system, msg_control_id, event_type, event_ts, received_ts,
       facility, visit_number, mrn, patient_class, location, attending_npi,
       admit_ts, discharge_ts
FROM landing.adt_event WHERE batch_id = DATE '2026-11-02';
CALL etl.load_adt_batch(DATE '2026-11-02');
SQL

psql -X -v ON_ERROR_STOP=1 -d "$DB" -f sql/reports/20_load_report.sql
