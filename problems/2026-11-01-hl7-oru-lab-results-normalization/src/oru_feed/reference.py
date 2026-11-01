"""Reference data: lab registry, local-code -> LOINC crosswalk, unit conversions.

All three live in plain CSV files under ``config/`` so a new lab can be
onboarded by adding rows, not by changing code.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo


def normalize_unit(unit: str) -> str:
    """Make unit strings comparable: 'UMOL/L', 'µmol/L', 'umol/l' -> 'umol/l'."""
    return unit.strip().replace("µ", "u").replace("μ", "u").lower()


@dataclass(frozen=True)
class Conversion:
    canonical_unit: str
    factor: float
    offset: float

    def apply(self, value: float) -> float:
        return value * self.factor + self.offset


@dataclass
class ReferenceData:
    lab_timezones: dict[str, ZoneInfo]
    crosswalk: dict[tuple[str, str], tuple[str, str]]          # (facility, local) -> (loinc, display)
    conversions: dict[str, dict[str, Conversion]]              # loinc -> {source_unit: Conversion}

    @classmethod
    def load(cls, config_dir: str | Path) -> "ReferenceData":
        cfg = Path(config_dir)
        with open(cfg / "labs.csv", newline="") as f:
            tz = {r["sending_facility"]: ZoneInfo(r["default_timezone"]) for r in csv.DictReader(f)}
        with open(cfg / "loinc_crosswalk.csv", newline="") as f:
            xw = {(r["sending_facility"], r["local_code"].upper()): (r["loinc"], r["loinc_display"])
                  for r in csv.DictReader(f)}
        conv: dict[str, dict[str, Conversion]] = {}
        with open(cfg / "unit_conversions.csv", newline="") as f:
            for r in csv.DictReader(f):
                conv.setdefault(r["loinc"], {})[normalize_unit(r["source_unit"])] = Conversion(
                    r["canonical_unit"], float(r["factor"]), float(r["offset"]))
        return cls(tz, xw, conv)

    def to_loinc(self, facility: str, code: str, system: str,
                 alt_code: str = "", alt_system: str = "") -> str | None:
        """Resolve an OBX-3 coded element to LOINC.

        Order: primary triplet is LN -> alternate triplet is LN -> crosswalk.
        """
        if system.upper() == "LN" and code:
            return code
        if alt_system.upper() == "LN" and alt_code:
            return alt_code
        hit = self.crosswalk.get((facility, code.upper()))
        return hit[0] if hit else None

    def convert(self, loinc: str, value: float, unit: str) -> tuple[float, str] | None:
        """Convert to the canonical unit; None means the unit is not accepted.

        LOINCs without any configured conversions are passed through unchanged.
        """
        rules = self.conversions.get(loinc)
        if rules is None:
            return value, unit
        rule = rules.get(normalize_unit(unit))
        if rule is None:
            return None
        return round(rule.apply(value), 4), rule.canonical_unit
