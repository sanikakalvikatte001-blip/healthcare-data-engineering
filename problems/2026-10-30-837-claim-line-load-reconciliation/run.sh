#!/usr/bin/env bash
# Build the schema, generate the synthetic batch, load it (with simulated load
# bugs), run the reconciliation, and print the report.
#
# Uses standard libpq env vars: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE.
set -euo pipefail
cd "$(dirname "$0")"

PSQL="psql -X -q -v ON_ERROR_STOP=1"

for f in sql/00_schema.sql sql/01_functions.sql sql/02_generate_synthetic_source.sql \
         sql/03_load_with_defects.sql sql/04_rule_catalog.sql sql/05_run_reconciliation.sql; do
  echo ">> $f"
  $PSQL -f "$f"
done

echo ">> recon.run_reconciliation('B20261030')"
$PSQL -c "SELECT recon.run_reconciliation('B20261030') AS run_id;"

$PSQL -f sql/06_report.sql
