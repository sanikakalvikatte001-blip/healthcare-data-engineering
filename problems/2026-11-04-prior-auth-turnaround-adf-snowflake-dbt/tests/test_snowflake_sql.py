"""Parse every Snowflake script with sqlglot's Snowflake dialect.

There is no Snowflake account in CI, so this is a syntax-level guard; the
statements were written for and documented against Snowflake.
"""
from pathlib import Path

import pytest
import sqlglot

SQL_DIR = Path(__file__).resolve().parents[1] / "snowflake"
FILES = sorted(SQL_DIR.glob("*.sql"))


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.name)
def test_parses_as_snowflake(path):
    statements = sqlglot.parse(path.read_text(), read="snowflake")
    assert len([s for s in statements if s is not None]) >= 1


def test_raw_columns_match_local_emulator():
    """The local emulator (stand-in for COPY INTO) must create the same RAW columns."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "emu", SQL_DIR.parent / "scripts" / "local_adf_emulator.py")
    emu = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(emu)
    ddl = (SQL_DIR / "02_raw_and_control_tables.sql").read_text().lower()
    for table, cols in emu.TABLES.items():
        for col in cols + ["_file_name", "_loaded_at"]:
            assert f"    {col} " in ddl, f"{table}.{col} missing from Snowflake DDL"
