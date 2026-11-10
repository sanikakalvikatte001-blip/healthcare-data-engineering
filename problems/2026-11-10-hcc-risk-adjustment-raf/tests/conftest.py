import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from hcc_raf.config import load_config, load_reference_tables  # noqa: E402
from hcc_raf.pipeline import get_spark, run  # noqa: E402

MODEL_DIR = ROOT / "model"


@pytest.fixture(scope="session")
def spark():
    s = get_spark("hcc-raf-tests")
    yield s
    s.stop()


@pytest.fixture(scope="session")
def cfg():
    return load_config(MODEL_DIR)


@pytest.fixture(scope="session")
def ref(spark, cfg):
    return load_reference_tables(spark, MODEL_DIR, cfg)


@pytest.fixture(scope="session")
def result(spark, tmp_path_factory):
    """Full pipeline over freshly generated synthetic data."""
    data_dir = tmp_path_factory.mktemp("data")
    subprocess.run([sys.executable, str(ROOT / "scripts" / "generate_data.py"), "--out", str(data_dir)],
                   check=True, capture_output=True)
    return run(spark, data_dir, MODEL_DIR)
