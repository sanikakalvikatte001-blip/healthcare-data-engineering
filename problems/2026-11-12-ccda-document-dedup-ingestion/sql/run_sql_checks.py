"""Runs sql/load_and_reconcile.sql in an in-memory DuckDB and fails (exit 1) if any check fails.
Helper only - the solution itself is the C# pipeline; this is the warehouse-side reconciliation."""
import pathlib
import sys

import duckdb

sql = (pathlib.Path(__file__).parent / "load_and_reconcile.sql").read_text()
con = duckdb.connect()
*setup, final_select = [s for s in sql.split(";") if s.strip()]
for statement in setup:
    con.execute(statement)

rows = con.execute(final_select).fetchall()
for name, expected, actual, passed in rows:
    print(f"  {'PASS' if passed else 'FAIL'}  {name:<70} expected={expected:<4} actual={actual}")

print("\nManifest by status:")
for status, n in con.execute(
        "SELECT status, count(*) FROM ccda_document_manifest GROUP BY status ORDER BY status").fetchall():
    print(f"  {status:<19} {n}")

failed = sum(1 for r in rows if not r[3])
print(f"\n{len(rows) - failed}/{len(rows)} SQL reconciliation checks passed")
sys.exit(1 if failed else 0)
