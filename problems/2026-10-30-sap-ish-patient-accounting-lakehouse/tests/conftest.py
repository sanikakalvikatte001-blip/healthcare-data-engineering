"""Shared fixtures: one local Spark session and one full pipeline build per test run."""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from sap_lakehouse import pipeline  # noqa: E402
from sap_lakehouse.config import get_spark, load_settings  # noqa: E402


@pytest.fixture(scope="session")
def settings(tmp_path_factory):
    return load_settings(
        "local",
        landing_path=str(ROOT / "data" / "landing"),
        local_warehouse_dir=str(tmp_path_factory.mktemp("warehouse")),
    )


@pytest.fixture(scope="session")
def spark(settings):
    session = get_spark(settings)
    session.sparkContext.setLogLevel("ERROR")
    yield session
    session.stop()


@pytest.fixture(scope="session")
def built(spark, settings):
    """Run bronze -> silver -> gold once on the committed synthetic extracts."""
    return pipeline.run(spark, settings, ["bronze", "silver", "gold"])


@pytest.fixture(scope="session")
def planted():
    return json.loads((ROOT / "data" / "planted_defects.json").read_text())
