#!/usr/bin/env bash
# Build, generate synthetic data, reconcile, and run the tests.
set -euo pipefail
cd "$(dirname "$0")"

dotnet build Era835Recon.sln -nologo -v quiet

dotnet run --project src/Era835Recon.Cli --no-build -- generate --data data

# reconcile exits 2 when error-level exceptions exist (the synthetic data plants some on purpose).
set +e
dotnet run --project src/Era835Recon.Cli --no-build -- reconcile --data data --out output --as-of 2026-11-05
code=$?
set -e
[[ $code -eq 0 || $code -eq 2 ]] || exit $code
echo "reconcile exit code: $code (2 = exceptions need review)"

dotnet run --project tests/Era835Recon.Tests --no-build
