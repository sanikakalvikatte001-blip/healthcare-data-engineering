"""Load the de-identification policy (TOML) and enforce that it covers every column."""
from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

SIMPLE_RULES = {"keep", "drop", "year", "dob_to_age", "zip3", "scrub_text"}

# Column names that look like one of the 18 identifiers can never be "keep".
# Defense in depth: a typo in the policy shouldn't be the only thing between
# an SSN column and a research dataset.
IDENTIFIER_NAME_HINT = re.compile(
    # matched on whole underscore-separated tokens: "vin" hits "vehicle_vin", not "province"
    r"(?:^|_)(?:ssn|social_security|mrn|medical_record|first_name|last_name|full_name|"
    r"patient_name|phone|fax|email|street|address|member_id|subscriber_id|policy_number|"
    r"dob|birth_date|date_of_birth|license|vin|device_serial|ip_address|url)(?:_|$)",
    re.I,
)


class PolicyError(ValueError):
    """Raised when the policy is invalid or does not match the input data."""


@dataclass(frozen=True)
class Rule:
    kind: str                 # keep | drop | surrogate | year | dob_to_age | zip3 | scrub_text
    domain: str | None = None  # surrogate domain, e.g. "patient"

    @classmethod
    def parse(cls, text: str) -> "Rule":
        text = text.strip()
        if text.startswith("surrogate:"):
            domain = text.split(":", 1)[1].strip()
            if not domain.isidentifier():
                raise PolicyError(f"bad surrogate domain in rule {text!r}")
            return cls("surrogate", domain)
        if text not in SIMPLE_RULES:
            raise PolicyError(f"unknown rule {text!r}")
        return cls(text)


@dataclass(frozen=True)
class ScrubSpec:
    column: str
    link_table: str
    link_key: str
    known_values: tuple[str, ...]


@dataclass(frozen=True)
class TablePolicy:
    name: str
    file: str
    columns: dict[str, Rule]
    scrub: ScrubSpec | None = None


@dataclass(frozen=True)
class Policy:
    as_of_date: date
    small_cell_k: int
    restricted_zip3: frozenset[str]
    tables: dict[str, TablePolicy] = field(default_factory=dict)


def load_policy(path: str | Path) -> Policy:
    raw = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    tables: dict[str, TablePolicy] = {}
    for name, t in raw.get("tables", {}).items():
        cols = {c: Rule.parse(r) for c, r in t["columns"].items()}
        scrub = None
        if "scrub" in t:
            s = t["scrub"]
            scrub = ScrubSpec(s["column"], s["link_table"], s["link_key"], tuple(s["known_values"]))
            if cols.get(scrub.column, Rule("keep")).kind != "scrub_text":
                raise PolicyError(f"{name}.{scrub.column} has a scrub block but rule is not scrub_text")
        tables[name] = TablePolicy(name, t["file"], cols, scrub)

    # Linked scrub tables must exist and carry the referenced columns.
    for tp in tables.values():
        if tp.scrub:
            link = tables.get(tp.scrub.link_table)
            if link is None:
                raise PolicyError(f"{tp.name}: link_table {tp.scrub.link_table!r} not in policy")
            missing = [c for c in (tp.scrub.link_key, *tp.scrub.known_values) if c not in link.columns]
            if missing:
                raise PolicyError(f"{tp.name}: link columns not in {link.name}: {missing}")

    run = raw.get("run", {})
    return Policy(
        as_of_date=date.fromisoformat(run["as_of_date"]),
        small_cell_k=int(run.get("small_cell_k", 5)),
        restricted_zip3=frozenset(raw.get("zip3", {}).get("restricted", [])),
        tables=tables,
    )


def check_coverage(table: TablePolicy, input_columns: list[str]) -> None:
    """Fail closed: every input column needs a rule, and every rule needs a column."""
    unknown = [c for c in input_columns if c not in table.columns]
    missing = [c for c in table.columns if c not in input_columns]
    if unknown:
        raise PolicyError(
            f"{table.name}: columns with no de-identification rule: {unknown}. "
            "Add them to the policy (keep/drop/...) before this extract can be released."
        )
    if missing:
        raise PolicyError(f"{table.name}: policy columns not found in input: {missing}")
    risky = [c for c, r in table.columns.items() if r.kind == "keep" and IDENTIFIER_NAME_HINT.search(c)]
    if risky:
        raise PolicyError(f"{table.name}: identifier-like columns marked keep: {risky}")
