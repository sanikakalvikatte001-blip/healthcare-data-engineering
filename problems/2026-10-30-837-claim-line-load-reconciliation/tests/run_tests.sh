#!/usr/bin/env bash
# Rebuild everything from scratch, then run the SQL test suite.
set -euo pipefail
cd "$(dirname "$0")/.."

PSQL="psql -X -q -v ON_ERROR_STOP=1"

for f in sql/00_schema.sql sql/01_functions.sql sql/02_generate_synthetic_source.sql \
         sql/03_load_with_defects.sql sql/04_rule_catalog.sql sql/05_run_reconciliation.sql; do
  $PSQL -f "$f" > /dev/null 2>&1
done

$PSQL -f tests/test_reconciliation.sql 2>&1 | grep -E 'PASS|FAIL|ERROR|ALL TESTS'
exit "${PIPESTATUS[0]}"
