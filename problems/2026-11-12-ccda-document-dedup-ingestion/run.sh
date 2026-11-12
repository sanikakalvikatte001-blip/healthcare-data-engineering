#!/usr/bin/env bash
# Build, generate the synthetic HIE drops, ingest two daily batches, reconcile in SQL, run tests.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf data/inbox output
dotnet build CcdaIngest.sln -nologo -v quiet

APP="dotnet run --project src/CcdaIngest --no-build --"
$APP generate --inbox data/inbox
$APP ingest --inbox data/inbox/batch1 --batch-id batch1 --out output
$APP ingest --inbox data/inbox/batch2 --batch-id batch2 --out output

echo "=== DuckDB load + reconciliation ==="
python3 sql/run_sql_checks.py | tee output/sql_reconciliation.txt

echo "=== Tests ==="
dotnet run --project tests/CcdaIngest.Tests --no-build
