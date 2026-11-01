import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from oru_feed.reference import ReferenceData  # noqa: E402


@pytest.fixture(scope="session")
def ref():
    return ReferenceData.load(ROOT / "config")


@pytest.fixture(scope="session")
def root():
    return ROOT
