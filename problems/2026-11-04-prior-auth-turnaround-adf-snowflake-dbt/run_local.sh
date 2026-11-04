#!/usr/bin/env bash
# Local end-to-end run: emulated ADF/COPY INTO loads -> dbt on DuckDB.
#   1. batch 0 (history through 2026-10-15) -> dbt build   (initial load)
#   2. daily batches 1..17 -> dbt build after each      (incremental + snapshot)
#   3. re-run the last batch load                       (COPY load history = no-op)
#   4. full-refresh the fact and prove it equals the incremental result
#   5. pytest: ADF definitions + Snowflake DDL parse checks
set -euo pipefail
cd "$(dirname "$0")"
DBT="dbt --no-use-colors"
export DBT_PROFILES_DIR="$PWD/dbt"

python scripts/generate_um_extracts.py
rm -f dbt/um_local.duckdb

for batch in $(seq 0 17); do
    echo "== batch $batch =="
    python scripts/local_adf_emulator.py --batch "$batch"
    (cd dbt && $DBT build --quiet --warn-error-options '{"silence": ["NoNodesForSelectionCriteria"]}') \
        || { echo "dbt build failed on batch $batch"; exit 1; }
done

echo "== batch 17 again (idempotency) =="; python scripts/local_adf_emulator.py --batch 17

echo "== incremental vs full refresh =="
(cd dbt && $DBT run-operation clone_relation --args '{from: marts.fct_prior_auth_request, to: audit.fct_incremental}' \
        && $DBT run --full-refresh -s fct_prior_auth_request \
        && $DBT run-operation assert_relations_equal \
              --args '{a: marts.fct_prior_auth_request, b: audit.fct_incremental}')

echo "== export results =="
(cd dbt && $DBT run-operation export_results)

echo "== static checks (ADF JSON + Snowflake SQL) =="
python -m pytest -q tests
