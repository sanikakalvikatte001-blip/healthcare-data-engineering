"""Release gate: checks run on the de-identified tables before anything is written.

A failed check blocks the release. Small quasi-identifier cells are reported as
a warning: Safe Harbor doesn't require k-anonymity, but the covered entity must
have no "actual knowledge" that the data could identify someone, so a privacy
reviewer should see them.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

import polars as pl

from .policy import Policy
from .text_scrub import contains_known, find_residual
from .transforms import AGE_TOP_CODE


@dataclass
class Check:
    name: str
    table: str
    status: str          # pass | fail | warn
    detail: str

    def to_dict(self) -> dict:
        return asdict(self)


def check_removed_columns(table: str, out: pl.DataFrame, removed: list[str]) -> Check:
    """No source column that was dropped or replaced may appear under its own name."""
    leaked = sorted(set(out.columns) & set(removed))
    return Check("removed_columns_absent", table, "fail" if leaked else "pass",
                 f"leaked columns: {leaked}" if leaked else f"{len(removed)} source columns removed/renamed")


def check_residual_patterns(table: str, out: pl.DataFrame) -> Check:
    """Scan every string cell with the PHI detectors (SSN, phone, e-mail, dates ...)."""
    hits: dict[str, int] = {}
    for col in [c for c, t in out.schema.items() if t == pl.Utf8]:
        for v in out[col].to_list():
            for tag in find_residual(v):
                key = f"{col}:{tag}"
                hits[key] = hits.get(key, 0) + 1
    return Check("residual_phi_patterns", table, "fail" if hits else "pass",
                 f"hits: {hits}" if hits else "0 pattern hits in string columns")


def check_identifier_values(table: str, out: pl.DataFrame, identifier_values: set[str]) -> Check:
    """No cell may equal an original identifier value (catches a column that was
    copied or mis-mapped, e.g. MRN landing in a 'keep' column)."""
    hits = 0
    for col in [c for c, t in out.schema.items() if t == pl.Utf8]:
        hits += int(out[col].is_in(list(identifier_values)).sum())
    return Check("no_original_identifier_values", table, "fail" if hits else "pass",
                 f"{hits} cells equal an original identifier" if hits
                 else f"checked against {len(identifier_values)} original identifier values")


def check_known_values_in_text(table: str, texts: list[str | None],
                               knowns: list[list[str | None]]) -> Check:
    """Row-level: the patient's own name/MRN/phone/... must not remain in their note."""
    leaks = sum(1 for t, k in zip(texts, knowns) if contains_known(t, k))
    return Check("known_values_scrubbed", table, "fail" if leaks else "pass",
                 f"{leaks} notes still contain the patient's own identifiers" if leaks
                 else f"{len(texts)} notes checked")


def check_zip3(table: str, out: pl.DataFrame, policy: Policy) -> Check:
    col = out["zip3"]
    bad_format = int((~col.str.contains(r"^\d{3}$")).sum())
    restricted = int(col.is_in(list(policy.restricted_zip3)).sum())
    ok = bad_format == 0 and restricted == 0
    return Check("zip3_safe_harbor", table, "pass" if ok else "fail",
                 f"{int((col == '000').sum())} set to 000; bad_format={bad_format}, restricted_left={restricted}")


def check_age(table: str, out: pl.DataFrame) -> Check:
    over = int((out["age_years"] > AGE_TOP_CODE).sum())
    year_leak = int(((out["age_years"] >= AGE_TOP_CODE) & out["birth_year"].is_not_null()).sum())
    ok = over == 0 and year_leak == 0
    return Check("age_top_coded_90", table, "pass" if ok else "fail",
                 f"{int((out['age_years'] == AGE_TOP_CODE).sum())} top-coded at 90; "
                 f"over_90={over}, birth_year_left_for_90plus={year_leak}")


def check_small_cells(table: str, out: pl.DataFrame, quasi: list[str], k: int) -> Check:
    groups = out.group_by(quasi).len()
    small = groups.filter(pl.col("len") < k)
    rows_in_small = int(small["len"].sum()) if small.height else 0
    return Check(f"small_cells_k{k}", table, "warn" if small.height else "pass",
                 f"{small.height} of {groups.height} ({', '.join(quasi)}) groups have < {k} people "
                 f"({rows_in_small} of {out.height} rows) — review for actual-knowledge risk")
