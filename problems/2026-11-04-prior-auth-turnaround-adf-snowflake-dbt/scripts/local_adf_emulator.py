"""
Local stand-in for the ADF -> Snowflake load, so the dbt project can run
end to end without Azure or Snowflake accounts.

What it emulates (see adf/pipeline/pl_um_incremental_to_snowflake.json and
snowflake/03_copy_into_raw.sql for the real thing):
  * ADF Copy activity has already landed  data/landing/um/<table>/batch=<n>/*.csv
  * Snowflake COPY INTO appends the files to RAW tables, adds _file_name and
    _loaded_at metadata, and SKIPS files it has loaded before (load history),
    so re-running a batch is a no-op.

Usage:  python scripts/local_adf_emulator.py --batch 0 [--db dbt/um_local.duckdb]
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
TABLES = {
    "pa_request": ["request_id", "member_id", "requesting_npi", "line_of_business",
                   "service_category", "procedure_code", "submission_channel",
                   "received_at", "priority", "modified_at"],
    "pa_status_event": ["event_id", "request_id", "status", "event_at",
                        "reason_code", "modified_at"],
}
# simulated pipeline run time: 10 minutes after the batch's extract cutoff
# (batch 0 = initial load at 2026-10-15, batch n = n days later)
def load_time(batch: int) -> datetime:
    return datetime(2026, 10, 15, 0, 10) + timedelta(days=batch)


def load_batch(con: duckdb.DuckDBPyConnection, batch: int) -> None:
    con.execute("CREATE SCHEMA IF NOT EXISTS raw_um")
    con.execute("""CREATE TABLE IF NOT EXISTS raw_um.copy_load_history (
                       file_name VARCHAR PRIMARY KEY, table_name VARCHAR,
                       row_count BIGINT, loaded_at TIMESTAMP)""")
    for table, cols in TABLES.items():
        col_ddl = ", ".join(f"{c} VARCHAR" for c in cols)
        con.execute(f"""CREATE TABLE IF NOT EXISTS raw_um.{table} (
                            {col_ddl}, _file_name VARCHAR, _loaded_at TIMESTAMP)""")
        for path in sorted((ROOT / "data/landing/um" / table / f"batch={batch}").glob("*.csv")):
            file_name = str(path.relative_to(ROOT / "data/landing"))
            if con.execute("SELECT 1 FROM raw_um.copy_load_history WHERE file_name = ?",
                           [file_name]).fetchone():
                print(f"skip  {file_name} (already in load history)")
                continue
            loaded_at = load_time(batch) + timedelta(seconds=1 if table == "pa_status_event" else 0)
            select_cols = ", ".join(cols)
            n = con.execute(f"""
                INSERT INTO raw_um.{table}
                SELECT {select_cols}, ?, ?
                FROM read_csv(?, header = true, all_varchar = true)""",
                [file_name, loaded_at, str(path)]).fetchone()[0]
            con.execute("INSERT INTO raw_um.copy_load_history VALUES (?, ?, ?, ?)",
                        [file_name, table, n, loaded_at])
            print(f"load  {file_name}: {n} rows (_loaded_at {loaded_at})")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", type=int, required=True, choices=range(0, 18))
    ap.add_argument("--db", default=str(ROOT / "dbt" / "um_local.duckdb"))
    args = ap.parse_args()
    with duckdb.connect(args.db) as con:
        load_batch(con, args.batch)
