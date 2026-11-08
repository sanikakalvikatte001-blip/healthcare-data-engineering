"""Command line entry point:  python -m safeharbor --policy ... --input ... --out ..."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .pipeline import deidentify, read_inputs, write_outputs
from .policy import PolicyError, load_policy


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="safeharbor",
                                 description="HIPAA Safe Harbor de-identification with a release gate.")
    ap.add_argument("--policy", required=True, type=Path)
    ap.add_argument("--input", required=True, type=Path, help="folder with the source CSVs")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--seed", type=int, default=None,
                    help="seed surrogate keys (demos/tests only; omit in production)")
    args = ap.parse_args(argv)

    try:
        policy = load_policy(args.policy)
        result = deidentify(policy, read_inputs(policy, args.input), seed=args.seed)
    except PolicyError as exc:
        print(f"POLICY ERROR: {exc}", file=sys.stderr)
        return 2

    report = write_outputs(policy, result, args.out)
    for name, rc in report["tables"].items():
        print(f"{name:<11} rows {rc['input_rows']:>5} -> {rc['output_rows']:<5} "
              f"columns {rc['input_columns']:>2} -> {rc['output_columns']}")
    for name, red in report["text_redactions"].items():
        print(f"{name:<11} redactions: " + ", ".join(f"{k}={v}" for k, v in red.items()))
    for c in result.checks:
        print(f"  [{c.status.upper():4}] {c.table}.{c.name}: {c.detail}")
    print("RELEASED" if result.passed else "BLOCKED: release gate failed, no data written")
    return 0 if result.passed else 1
