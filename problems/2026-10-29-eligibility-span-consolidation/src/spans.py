"""Consolidate eligibility segments into coverage spans, find gaps, and check
HEDIS-style continuous enrollment.

Date convention: eff_date and term_date are both INCLUSIVE. A member termed on
2025-01-31 and re-effective on 2025-02-01 has no gap.
"""

from __future__ import annotations

from dataclasses import dataclass

import pandas as pd

KEYS = ["member_id", "plan_id"]
ONE_DAY = pd.Timedelta(days=1)


def load_segments(path) -> pd.DataFrame:
    """Read a segments CSV. Dates are parsed at second precision so the
    9999-12-31 high date fits (nanosecond timestamps stop at year 2262)."""
    df = pd.read_csv(path, dtype={"member_id": str, "plan_id": str})
    for col in ("eff_date", "term_date"):
        df[col] = df[col].astype("datetime64[s]")
    return df


def clean_segments(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """Remove invalid rows (term before eff) and exact duplicate date ranges.

    Returns the clean frame and a small stats dict for reporting.
    """
    invalid = df["term_date"] < df["eff_date"]
    valid = df.loc[~invalid]
    deduped = valid.drop_duplicates(subset=KEYS + ["eff_date", "term_date"])
    stats = {
        "input_rows": len(df),
        "invalid_rows": int(invalid.sum()),
        "duplicate_rows": len(valid) - len(deduped),
        "clean_rows": len(deduped),
    }
    return deduped.reset_index(drop=True), stats


def consolidate_spans(df: pd.DataFrame, allowed_gap_days: int = 0) -> pd.DataFrame:
    """Merge overlapping and adjacent segments into continuous spans.

    This is the classic "gaps and islands" pattern:
      1. Sort by member, plan, eff_date.
      2. Track the latest term_date seen so far in the group (running max).
         A running max is needed, not just the previous row, because one long
         segment can cover several shorter ones that follow it.
      3. A new island starts when eff_date is more than (allowed_gap_days + 1)
         days after that running max.
      4. Each island becomes one span: min(eff_date) to max(term_date).

    allowed_gap_days=0 merges only overlapping or touching segments.
    """
    if df.empty:
        return pd.DataFrame(columns=KEYS + ["span_eff", "span_term", "segment_count"])

    d = df.sort_values(KEYS + ["eff_date", "term_date"]).copy()
    d["prev_max_term"] = d.groupby(KEYS)["term_date"].transform(
        lambda s: s.cummax().shift(1)
    )
    tolerance = pd.Timedelta(days=allowed_gap_days + 1)
    d["new_island"] = d["prev_max_term"].isna() | (
        d["eff_date"] > d["prev_max_term"] + tolerance
    )
    d["island_id"] = d.groupby(KEYS)["new_island"].cumsum()

    spans = (
        d.groupby(KEYS + ["island_id"], as_index=False)
        .agg(
            span_eff=("eff_date", "min"),
            span_term=("term_date", "max"),
            segment_count=("eff_date", "size"),
        )
        .drop(columns="island_id")
    )
    return spans.sort_values(KEYS + ["span_eff"]).reset_index(drop=True)


def find_gaps(spans: pd.DataFrame) -> pd.DataFrame:
    """List the breaks between consecutive spans for each member and plan."""
    s = spans.sort_values(KEYS + ["span_eff"]).copy()
    s["next_eff"] = s.groupby(KEYS)["span_eff"].shift(-1)
    g = s.dropna(subset=["next_eff"]).copy()
    g["gap_start"] = g["span_term"] + ONE_DAY
    g["gap_end"] = g["next_eff"] - ONE_DAY
    g["gap_days"] = (g["gap_end"] - g["gap_start"]).dt.days + 1
    return g[KEYS + ["gap_start", "gap_end", "gap_days"]].reset_index(drop=True)


@dataclass(frozen=True)
class ContinuousEnrollmentRule:
    """HEDIS-style continuous enrollment rule.

    Most HEDIS measures allow at most one gap of up to 45 days in the
    measurement year, and the member must be enrolled on the anchor date.
    """

    period_start: str = "2025-01-01"
    period_end: str = "2025-12-31"
    anchor_date: str = "2025-12-31"
    max_gaps: int = 1
    max_gap_days: int = 45


def continuous_enrollment(
    spans: pd.DataFrame, rule: ContinuousEnrollmentRule = ContinuousEnrollmentRule()
) -> pd.DataFrame:
    """Check each member/plan against the rule.

    Gaps are measured inside the measurement period only, and uncovered days at
    the start or end of the period count as gaps too.
    """
    start = pd.Timestamp(rule.period_start)
    end = pd.Timestamp(rule.period_end)
    anchor = pd.Timestamp(rule.anchor_date)

    results = []
    for (member_id, plan_id), grp in spans.groupby(KEYS, sort=True):
        # Clip spans to the measurement period.
        inside = grp[(grp["span_term"] >= start) & (grp["span_eff"] <= end)]
        clipped = sorted(
            (max(e, start), min(t, end)) for e, t in zip(inside["span_eff"], inside["span_term"])
        )

        gap_lengths: list[int] = []
        cursor = start  # first day not yet known to be covered
        for eff, term in clipped:
            if eff > cursor:
                gap_lengths.append((eff - cursor).days)
            cursor = max(cursor, term + ONE_DAY)
        if cursor <= end:
            gap_lengths.append((end - cursor).days + 1)

        covered_days = (end - start).days + 1 - sum(gap_lengths)
        on_anchor = any(e <= anchor <= t for e, t in zip(grp["span_eff"], grp["span_term"]))

        if not clipped:
            reason = "no_coverage_in_period"
        elif not on_anchor:
            reason = "not_enrolled_on_anchor_date"
        elif len(gap_lengths) > rule.max_gaps:
            reason = "too_many_gaps"
        elif any(g > rule.max_gap_days for g in gap_lengths):
            reason = "gap_too_long"
        else:
            reason = "pass"

        results.append(
            {
                "member_id": member_id,
                "plan_id": plan_id,
                "covered_days": covered_days,
                "gap_count": len(gap_lengths),
                "longest_gap_days": max(gap_lengths, default=0),
                "enrolled_on_anchor": on_anchor,
                "continuously_enrolled": reason == "pass",
                "reason": reason,
            }
        )
    return pd.DataFrame(results)
