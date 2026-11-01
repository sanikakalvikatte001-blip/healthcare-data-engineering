"""Command-line entry point.

    python -m oru_feed --input data --config config --out output
"""
from __future__ import annotations

import argparse
import json
import sys

from .pipeline import process_feed, read_feed_dir, write_outputs
from .reference import ReferenceData


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="oru_feed",
                                description="Normalize HL7 v2 ORU^R01 lab feeds to LOINC observations")
    p.add_argument("--input", default="data", help="folder of *.hl7 feed files")
    p.add_argument("--config", default="config", help="folder with labs/crosswalk/unit CSVs")
    p.add_argument("--out", default="output", help="output folder")
    p.add_argument("--fail-on-reject-rate", type=float, default=None,
                   help="exit 2 if rejected OBX share exceeds this fraction (e.g. 0.10)")
    a = p.parse_args(argv)

    ref = ReferenceData.load(a.config)
    result = process_feed(read_feed_dir(a.input), ref)
    summary = write_outputs(result, a.out)
    print(json.dumps(summary, indent=2))

    if a.fail_on_reject_rate is not None:
        obx_rejects = sum(1 for r in result.rejects if r.obx_set_id is not None)
        total = obx_rejects + result.observations_parsed
        rate = obx_rejects / total if total else 0.0
        if rate > a.fail_on_reject_rate:
            print(f"OBX reject rate {rate:.1%} exceeds threshold {a.fail_on_reject_rate:.1%}",
                  file=sys.stderr)
            return 2
    return 0
