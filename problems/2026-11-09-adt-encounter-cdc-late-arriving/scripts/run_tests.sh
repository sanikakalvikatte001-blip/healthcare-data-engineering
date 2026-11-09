#!/usr/bin/env bash
# 1) Scenario tests on a clean database with hand-built ADT messages.
# 2) End-to-end test on the full synthetic feed (built by run_demo.sh).
# Any failed assertion raises and stops the script with a non-zero exit.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DB="${TEST_DB:-adt_cdc_test}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=notice"

echo "### scenario tests ($TEST_DB)"
dropdb --if-exists "$TEST_DB" 2>/dev/null
createdb "$TEST_DB"
for f in sql/ddl/01_schemas_and_tables.sql sql/procs/02_fold_encounter.sql \
         sql/procs/03_load_adt_batch.sql tests/00_assert_helpers.sql; do
    PGOPTIONS="-c client_min_messages=warning" psql -X -q -v ON_ERROR_STOP=1 -d "$TEST_DB" -f "$f"
done
psql -X -q -v ON_ERROR_STOP=1 -d "$TEST_DB" -f tests/10_test_scenarios.sql 2>&1 \
    | grep -E 'PASS|FAIL|ERROR|WARNING' | sed -E 's/^.*NOTICE:  //'

echo "### end-to-end test (synthetic feed)"
DB="${TEST_DB}_e2e" ./scripts/run_demo.sh > /dev/null
PGOPTIONS="-c client_min_messages=warning" \
    psql -X -q -v ON_ERROR_STOP=1 -d "${TEST_DB}_e2e" -f tests/00_assert_helpers.sql
psql -X -q -v ON_ERROR_STOP=1 -d "${TEST_DB}_e2e" -f tests/20_test_end_to_end.sql 2>&1 \
    | grep -E 'PASS|FAIL|ERROR' | sed -E 's/^.*NOTICE:  //'

echo "### all tests passed"
