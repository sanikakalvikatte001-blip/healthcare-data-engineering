import json
import os
import sys
import time
from pathlib import Path

import pytest

# Spark returns naive datetimes in the local zone; pin it so assertions are portable.
os.environ["TZ"] = "UTC"
time.tzset()

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))

from flatten_fhir import build_spark, run_pipeline  # noqa: E402


@pytest.fixture(scope="session")
def spark():
    s = build_spark("fhir-flatten-tests")
    s.sparkContext.setLogLevel("ERROR")
    yield s
    s.stop()


def collect_all(spark, input_dir) -> dict[str, list[dict]]:
    """Run the pipeline and pull every output view into Python right away.

    Temp views are session-wide and get replaced by the next run, so results are
    materialised here instead of passing DataFrames around between tests.
    """
    tables = run_pipeline(spark, input_dir)
    return {name: [r.asDict(recursive=True) for r in df.collect()] for name, df in tables.items()}


@pytest.fixture(scope="session")
def export_run(spark):
    """Pipeline output for the committed synthetic export in data/export."""
    return collect_all(spark, PROJECT / "data" / "export")


@pytest.fixture(scope="session")
def defects():
    return json.loads((PROJECT / "data" / "planted_defects.json").read_text())


def write_ndjson(folder: Path, name: str, resources: list) -> None:
    """Write resources (dicts, or raw strings for broken lines) as one NDJSON file."""
    folder.mkdir(parents=True, exist_ok=True)
    with open(folder / name, "w") as fh:
        for r in resources:
            fh.write((r if isinstance(r, str) else json.dumps(r)) + "\n")
