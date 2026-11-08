"""Orchestrates one de-identification run.

    read CSVs -> check policy coverage (fail closed) -> register surrogates
    -> apply column rules -> scrub notes -> release-gate checks
    -> write de-identified tables + restricted crosswalks + audit report

Nothing is written to the release folder unless every check passes.
"""
from __future__ import annotations

import json
import shutil
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import polars as pl

from . import verify
from .policy import Policy, check_coverage
from .text_scrub import scrub_many
from .transforms import SurrogateRegistry, dob_to_age, output_name, to_year, to_zip3


@dataclass
class RunResult:
    tables: dict[str, pl.DataFrame]
    checks: list[verify.Check]
    redactions: dict[str, dict[str, int]]
    registry: SurrogateRegistry
    row_counts: dict[str, dict[str, int]] = field(default_factory=dict)

    @property
    def passed(self) -> bool:
        return all(c.status != "fail" for c in self.checks)


def read_inputs(policy: Policy, input_dir: Path) -> dict[str, pl.DataFrame]:
    # Read every column as text: identifiers like ZIP "02108" or MRN must never be
    # coerced to numbers (leading zeros lost, or worse, silently mismatched).
    return {name: pl.read_csv(input_dir / tp.file, infer_schema=False)
            for name, tp in policy.tables.items()}


def deidentify(policy: Policy, sources: dict[str, pl.DataFrame], seed: int | None = None) -> RunResult:
    for name, tp in policy.tables.items():
        check_coverage(tp, sources[name].columns)

    # 1. Surrogates first, across all tables, so a domain is consistent everywhere.
    registry = SurrogateRegistry(seed)
    for name, tp in policy.tables.items():
        for col, rule in tp.columns.items():
            if rule.kind == "surrogate":
                registry.register(rule.domain, sources[name][col].to_list())

    out_tables: dict[str, pl.DataFrame] = {}
    redactions: dict[str, dict[str, int]] = {}
    checks: list[verify.Check] = []
    knowns_by_table: dict[str, tuple[list, list]] = {}

    for name, tp in policy.tables.items():
        src = sources[name]
        exprs: list[pl.Expr] = []
        for col, rule in tp.columns.items():
            if rule.kind in ("keep", "scrub_text"):
                exprs.append(pl.col(col))
            elif rule.kind == "surrogate":
                exprs.append(registry.expr(col, rule.domain))
            elif rule.kind == "year":
                exprs.append(to_year(col))
            elif rule.kind == "zip3":
                exprs.append(to_zip3(col, policy.restricted_zip3))
            elif rule.kind == "dob_to_age":
                exprs.extend(dob_to_age(col, policy.as_of_date))
            # "drop": no expression -> column is not selected
        out = src.select(exprs)

        # 2. Free-text scrubbing using the linked patient's known identifiers.
        if tp.scrub:
            s = tp.scrub
            link = sources[s.link_table].select(
                pl.col(s.link_key).alias("__link_key"),
                *[pl.col(c).alias(f"__k_{c}") for c in s.known_values])
            joined = src.select(pl.col(s.link_key).alias("__link_key")).join(
                link, on="__link_key", how="left", maintain_order="left")
            known_rows = [dict(zip(s.known_values, row))
                          for row in joined.select([f"__k_{c}" for c in s.known_values]).iter_rows()]
            texts, counts = scrub_many(src[s.column].to_list(), known_rows)
            out = out.with_columns(pl.Series(s.column, texts, dtype=pl.Utf8))
            redactions[name] = dict(sorted(counts.items()))
            knowns_by_table[name] = (texts, [list(k.values()) for k in known_rows])

        out_tables[name] = out

    # 3. Release gate.
    identifier_values: set[str] = set()
    for name, tp in policy.tables.items():
        for col, rule in tp.columns.items():
            if rule.kind in ("drop", "surrogate", "dob_to_age"):
                identifier_values.update(v for v in sources[name][col].drop_nulls().to_list()
                                         if len(v) >= 4)

    for name, tp in policy.tables.items():
        out = out_tables[name]
        removed = [c for c, r in tp.columns.items()
                   if r.kind not in ("keep", "scrub_text") and output_name(c, r.kind, r.domain) != [c]]
        checks.append(verify.check_removed_columns(name, out, removed))
        checks.append(verify.check_residual_patterns(name, out))
        checks.append(verify.check_identifier_values(name, out, identifier_values))
        if name in knowns_by_table:
            checks.append(verify.check_known_values_in_text(name, *knowns_by_table[name]))
        if "zip3" in out.columns:
            checks.append(verify.check_zip3(name, out, policy))
        if "age_years" in out.columns:
            checks.append(verify.check_age(name, out))
            quasi = [c for c in ("zip3", "birth_year", "sex") if c in out.columns]
            checks.append(verify.check_small_cells(name, out, quasi, policy.small_cell_k))

    row_counts = {n: {"input_rows": sources[n].height, "output_rows": out_tables[n].height,
                      "input_columns": sources[n].width, "output_columns": out_tables[n].width}
                  for n in policy.tables}
    return RunResult(out_tables, checks, redactions, registry, row_counts)


def build_report(policy: Policy, result: RunResult) -> dict:
    rules = {n: {c: (f"surrogate:{r.domain}" if r.domain else r.kind) for c, r in tp.columns.items()}
             for n, tp in policy.tables.items()}
    rule_counts = {n: dict(Counter(v.split(":")[0] for v in cols.values())) for n, cols in rules.items()}
    return {
        "method": "HIPAA Safe Harbor, 45 CFR 164.514(b)(2)",
        "as_of_date": policy.as_of_date.isoformat(),
        "released": result.passed,
        "tables": result.row_counts,
        "rules_applied": rule_counts,
        "text_redactions": result.redactions,
        "surrogate_keys": {d: len(m) for d, m in result.registry.maps.items()},
        "checks": [c.to_dict() for c in result.checks],
    }


def write_outputs(policy: Policy, result: RunResult, out_dir: Path) -> dict:
    """Write the audit report always; write released data only if the gate passed."""
    out_dir.mkdir(parents=True, exist_ok=True)
    report = build_report(policy, result)
    (out_dir / "deid_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    release = out_dir / "release"
    restricted = out_dir / "restricted"
    for d in (release, restricted):   # never leave a stale release behind a failed run
        if d.exists():
            shutil.rmtree(d)
    if not result.passed:
        return report

    release.mkdir()
    for name, tp in policy.tables.items():
        result.tables[name].write_csv(release / tp.file)
    # Crosswalks are the re-identification key: kept apart from the release and
    # held by the honest broker only. Never shipped with the dataset.
    restricted.mkdir()
    for domain in result.registry.maps:
        result.registry.crosswalk(domain).write_csv(restricted / f"crosswalk_{domain}.csv")
    return report
