"""Generate synthetic member eligibility segments, like rows loaded from 834 files.

Real eligibility feeds are messy. The same member often has:
  * monthly segments that should be one continuous span
  * overlapping segments from retro adds and re-sends
  * exact duplicates when the same 834 file is loaded twice
  * short and long breaks in coverage
  * open-ended coverage using the high date 9999-12-31
  * bad rows where term_date is before eff_date

All data is synthetic. No real member information is used.
"""

from __future__ import annotations

import argparse
import random
from datetime import date, timedelta
from pathlib import Path

import pandas as pd

HIGH_DATE = date(9999, 12, 31)
PLANS = ["MCD-HMO", "MCR-ADV", "COMM-PPO"]
SCENARIOS = [
    "single_span",
    "monthly_segments",
    "overlap_retro",
    "duplicate_load",
    "short_gap",
    "long_gap",
    "two_gaps",
    "termed_early",
    "late_start",
    "open_ended",
    "invalid_row",
]


def _month_start(year: int, month: int) -> date:
    return date(year, month, 1)


def _month_end(year: int, month: int) -> date:
    nxt = date(year + (month // 12), month % 12 + 1, 1)
    return nxt - timedelta(days=1)


def _segments_for(scenario: str, rng: random.Random) -> list[tuple[date, date]]:
    """Return (eff_date, term_date) pairs for one member, based on a scenario."""
    y = 2025
    if scenario == "single_span":
        return [(date(2024, 7, 1), date(2025, 12, 31))]
    if scenario == "monthly_segments":
        return [(_month_start(y, m), _month_end(y, m)) for m in range(1, 13)]
    if scenario == "overlap_retro":
        return [
            (date(2025, 1, 1), date(2025, 6, 30)),
            (date(2025, 5, 1), date(2025, 9, 30)),  # retro add overlaps
            (date(2025, 9, 15), date(2025, 12, 31)),
        ]
    if scenario == "duplicate_load":
        seg = (date(2025, 1, 1), date(2025, 12, 31))
        return [seg, seg]  # same file loaded twice
    if scenario == "short_gap":
        gap = rng.randint(10, 45)
        first_term = date(2025, 4, 30)
        return [
            (date(2025, 1, 1), first_term),
            (first_term + timedelta(days=gap + 1), date(2025, 12, 31)),
        ]
    if scenario == "long_gap":
        return [
            (date(2025, 1, 1), date(2025, 3, 31)),
            (date(2025, 7, 1), date(2025, 12, 31)),
        ]
    if scenario == "two_gaps":
        return [
            (date(2025, 1, 1), date(2025, 3, 31)),
            (date(2025, 4, 21), date(2025, 8, 31)),
            (date(2025, 9, 16), date(2025, 12, 31)),
        ]
    if scenario == "termed_early":
        return [(date(2025, 1, 1), date(2025, 11, 30))]
    if scenario == "late_start":
        start = date(2025, 1, 1) + timedelta(days=rng.randint(20, 120))
        return [(start, HIGH_DATE)]
    if scenario == "open_ended":
        return [(date(2023, 3, 1), HIGH_DATE)]
    if scenario == "invalid_row":
        return [
            (date(2025, 1, 1), date(2025, 12, 31)),
            (date(2025, 8, 1), date(2025, 7, 1)),  # term before eff
        ]
    raise ValueError(f"Unknown scenario: {scenario}")


def generate(n_members: int = 500, seed: int = 42) -> pd.DataFrame:
    """Build a DataFrame of eligibility segments for n_members synthetic members."""
    rng = random.Random(seed)
    rows = []
    seg_id = 1
    for i in range(1, n_members + 1):
        member_id = f"M{i:06d}"
        plan_id = rng.choice(PLANS)
        scenario = rng.choice(SCENARIOS)
        segments = _segments_for(scenario, rng)
        rng.shuffle(segments)  # feeds do not arrive in date order
        for eff, term in segments:
            rows.append(
                {
                    "segment_id": seg_id,
                    "member_id": member_id,
                    "plan_id": plan_id,
                    "eff_date": eff.isoformat(),
                    "term_date": term.isoformat(),
                    "source_file": f"834_{rng.choice(['0105', '0205', '0305', '0405'])}2025.edi",
                    "scenario": scenario,  # kept only to help explain results
                }
            )
            seg_id += 1
    return pd.DataFrame(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--members", type=int, default=500)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data" / "eligibility_segments.csv",
    )
    args = parser.parse_args()
    df = generate(args.members, args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(args.out, index=False)
    print(f"Wrote {len(df):,} segments for {df['member_id'].nunique():,} members to {args.out}")


if __name__ == "__main__":
    main()
