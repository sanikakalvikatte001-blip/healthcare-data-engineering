"""Tests for eligibility span consolidation, gaps, and continuous enrollment."""

import sys
from pathlib import Path

import pandas as pd
import pytest

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from generate_data import generate  # noqa: E402
from run_pipeline import run_sql, spans_match  # noqa: E402
from spans import (  # noqa: E402
    ContinuousEnrollmentRule,
    clean_segments,
    consolidate_spans,
    continuous_enrollment,
    find_gaps,
)


def seg(rows):
    """Build a segments frame from (member, eff, term) tuples, one plan."""
    df = pd.DataFrame(rows, columns=["member_id", "eff_date", "term_date"])
    df["plan_id"] = "MCD-HMO"
    for col in ("eff_date", "term_date"):
        df[col] = df[col].astype("datetime64[s]")
    return df


def spans_as_str(spans):
    return [(str(e)[:10], str(t)[:10]) for e, t in zip(spans["span_eff"], spans["span_term"])]


# ---------- consolidation ----------

def test_adjacent_monthly_segments_merge_into_one_span():
    df = seg([("A", "2025-01-01", "2025-01-31"), ("A", "2025-02-01", "2025-02-28"),
              ("A", "2025-03-01", "2025-03-31")])
    spans = consolidate_spans(df)
    assert spans_as_str(spans) == [("2025-01-01", "2025-03-31")]
    assert spans["segment_count"].tolist() == [3]


def test_overlapping_segments_merge():
    df = seg([("A", "2025-01-01", "2025-06-30"), ("A", "2025-05-01", "2025-09-30")])
    assert spans_as_str(consolidate_spans(df)) == [("2025-01-01", "2025-09-30")]


def test_long_segment_covering_shorter_ones_uses_running_max():
    # A plain LAG on term_date would wrongly split after the short March segment.
    df = seg([("A", "2025-01-01", "2025-12-31"), ("A", "2025-03-01", "2025-03-31"),
              ("A", "2025-06-01", "2025-06-30")])
    assert spans_as_str(consolidate_spans(df)) == [("2025-01-01", "2025-12-31")]


def test_one_day_gap_creates_two_spans():
    df = seg([("A", "2025-01-01", "2025-01-30"), ("A", "2025-02-01", "2025-02-28")])
    assert len(consolidate_spans(df)) == 2


def test_allowed_gap_days_bridges_small_breaks():
    df = seg([("A", "2025-01-01", "2025-01-30"), ("A", "2025-02-01", "2025-02-28")])
    assert len(consolidate_spans(df, allowed_gap_days=1)) == 1


def test_members_are_not_merged_together():
    df = seg([("A", "2025-01-01", "2025-06-30"), ("B", "2025-07-01", "2025-12-31")])
    assert len(consolidate_spans(df)) == 2


def test_high_date_open_ended_coverage():
    df = seg([("A", "2023-01-01", "9999-12-31"), ("A", "2025-01-01", "2025-03-31")])
    assert spans_as_str(consolidate_spans(df)) == [("2023-01-01", "9999-12-31")]


# ---------- cleaning ----------

def test_clean_removes_invalid_and_duplicate_rows():
    df = seg([("A", "2025-01-01", "2025-12-31"), ("A", "2025-01-01", "2025-12-31"),
              ("A", "2025-08-01", "2025-07-01")])
    clean, stats = clean_segments(df)
    assert stats == {"input_rows": 3, "invalid_rows": 1, "duplicate_rows": 1, "clean_rows": 1}
    assert len(clean) == 1


# ---------- gaps ----------

def test_find_gaps_reports_inclusive_gap_dates():
    df = seg([("A", "2025-01-01", "2025-03-31"), ("A", "2025-07-01", "2025-12-31")])
    gaps = find_gaps(consolidate_spans(df))
    assert len(gaps) == 1
    g = gaps.iloc[0]
    assert str(g["gap_start"])[:10] == "2025-04-01"
    assert str(g["gap_end"])[:10] == "2025-06-30"
    assert g["gap_days"] == 91


# ---------- continuous enrollment ----------

@pytest.mark.parametrize(
    "rows, expected_reason",
    [
        ([("A", "2025-01-01", "2025-12-31")], "pass"),
        ([("A", "2025-01-01", "2025-04-30"), ("A", "2025-06-15", "2025-12-31")], "pass"),  # 45-day gap
        ([("A", "2025-01-01", "2025-04-30"), ("A", "2025-06-16", "2025-12-31")], "gap_too_long"),  # 46 days
        ([("A", "2025-01-01", "2025-03-31"), ("A", "2025-04-11", "2025-08-31"),
          ("A", "2025-09-11", "2025-12-31")], "too_many_gaps"),
        ([("A", "2025-01-01", "2025-11-30")], "not_enrolled_on_anchor_date"),
        ([("A", "2025-02-01", "9999-12-31")], "pass"),  # 31-day gap at start of year
        ([("A", "2023-01-01", "2024-06-30")], "no_coverage_in_period"),
    ],
)
def test_continuous_enrollment_reasons(rows, expected_reason):
    result = continuous_enrollment(consolidate_spans(seg(rows)), ContinuousEnrollmentRule())
    assert result["reason"].iloc[0] == expected_reason


def test_continuous_enrollment_counts_covered_days():
    rows = [("A", "2025-01-01", "2025-04-30"), ("A", "2025-06-15", "2025-12-31")]
    r = continuous_enrollment(consolidate_spans(seg(rows))).iloc[0]
    assert r["covered_days"] == 365 - 45
    assert r["gap_count"] == 1 and r["longest_gap_days"] == 45


# ---------- Python vs SQL ----------

def test_sql_and_python_produce_the_same_spans(tmp_path):
    raw = generate(n_members=300, seed=7)
    csv = tmp_path / "segments.csv"
    raw.to_csv(csv, index=False)

    df = raw.copy()
    for col in ("eff_date", "term_date"):
        df[col] = df[col].astype("datetime64[s]")
    clean, _ = clean_segments(df)
    py_spans = consolidate_spans(clean)
    sql_spans = run_sql(csv)

    assert spans_match(py_spans, sql_spans)
