"""Column transforms for structured fields, written as polars expressions.

Each function takes a column name and returns one or more named expressions,
so the pipeline can apply a whole table's policy in a single `select`.
"""
from __future__ import annotations

import random
import secrets
from datetime import date

import polars as pl

AGE_TOP_CODE = 90  # Safe Harbor: ages over 89 are aggregated into "90 or older"


def output_name(column: str, kind: str, domain: str | None = None) -> list[str]:
    """Output column name(s) for a rule. Renaming makes it obvious in the
    released data that a field was transformed (zip -> zip3, dob -> age_years)."""
    if kind == "surrogate":
        return [f"{domain}_key"]
    if kind == "year":
        return [column[:-5] + "_year" if column.endswith("_date") else column + "_year"]
    if kind == "zip3":
        return [column + "3"]
    if kind == "dob_to_age":
        return ["age_years", "birth_year"]
    if kind == "drop":
        return []
    return [column]


def to_year(column: str) -> pl.Expr:
    """ISO date string -> integer year. Month and day are removed."""
    return (pl.col(column).str.to_date("%Y-%m-%d", strict=False).dt.year()
            .alias(output_name(column, "year")[0]))


def to_zip3(column: str, restricted: frozenset[str]) -> pl.Expr:
    """ZIP / ZIP+4 -> first 3 digits; restricted or malformed ZIPs -> '000'."""
    z3 = pl.col(column).str.strip_chars().str.slice(0, 3)
    valid = z3.str.contains(r"^\d{3}$").fill_null(False)
    return (pl.when(valid & ~z3.is_in(list(restricted)))
            .then(z3).otherwise(pl.lit("000"))
            .alias(output_name(column, "zip3")[0]))


def dob_to_age(column: str, as_of: date) -> list[pl.Expr]:
    """Date of birth -> age in whole years (top-coded at 90) and birth year.

    Safe Harbor also requires removing any *year* that reveals an age over 89,
    so birth_year is null for anyone top-coded.
    """
    dob = pl.col(column).str.to_date("%Y-%m-%d", strict=False)
    not_had_birthday = (dob.dt.month() > as_of.month) | (
        (dob.dt.month() == as_of.month) & (dob.dt.day() > as_of.day))
    age = pl.lit(as_of.year) - dob.dt.year() - not_had_birthday.cast(pl.Int32)
    return [
        pl.min_horizontal(age, pl.lit(AGE_TOP_CODE)).cast(pl.Int32).alias("age_years"),
        pl.when(age >= AGE_TOP_CODE).then(None).otherwise(dob.dt.year())
          .cast(pl.Int32).alias("birth_year"),
    ]


class SurrogateRegistry:
    """Random surrogate keys per domain, shared across tables.

    The same MRN gets the same patient_key in patients and encounters, so the
    released tables still join. Tokens are random (not a hash of the MRN), as
    164.514(c) requires for a re-identification code. Pass a seed only for
    reproducible demos and tests; production uses the OS CSPRNG.
    """

    def __init__(self, seed: int | None = None):
        self._rng = random.Random(seed) if seed is not None else secrets.SystemRandom()
        self.maps: dict[str, dict[str, str]] = {}

    def register(self, domain: str, values: list[str | None]) -> None:
        mapping = self.maps.setdefault(domain, {})
        used = set(mapping.values())
        prefix = domain[:3].upper()
        for v in sorted({v for v in values if v is not None}):
            if v in mapping:
                continue
            while True:
                token = f"{prefix}-{self._rng.getrandbits(48):012x}"
                if token not in used:
                    break
            mapping[v] = token
            used.add(token)

    def expr(self, column: str, domain: str) -> pl.Expr:
        mapping = self.maps[domain]
        return (pl.col(column).replace_strict(mapping, default=None, return_dtype=pl.Utf8)
                .alias(output_name(column, "surrogate", domain)[0]))

    def crosswalk(self, domain: str) -> pl.DataFrame:
        m = self.maps[domain]
        return pl.DataFrame({"source_value": list(m.keys()), f"{domain}_key": list(m.values())})
