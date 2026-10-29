"""Run the full pipeline: segments -> clean -> spans -> gaps -> continuous enrollment.

Also runs the same consolidation in SQL (DuckDB) and checks that both match.
Outputs are written to the output/ folder.
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import pandas as pd

from spans import (
    clean_segments,
    consolidate_spans,
    continuous_enrollment,
    find_gaps,
    load_segments,
)

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data" / "eligibility_segments.csv"
SQL = ROOT / "src" / "consolidate_spans.sql"
OUT = ROOT / "output"


def run_sql(csv_path: Path) -> pd.DataFrame:
    """Consolidate spans with the SQL version, straight from the CSV."""
    con = duckdb.connect()
    con.execute(
        "CREATE TABLE segments AS SELECT member_id, plan_id, "
        "CAST(eff_date AS DATE) AS eff_date, CAST(term_date AS DATE) AS term_date "
        f"FROM read_csv('{csv_path.as_posix()}', header=true, all_varchar=true)"
    )
    return con.execute(SQL.read_text()).df()


def spans_match(py: pd.DataFrame, sql: pd.DataFrame) -> bool:
    """True if the Python and SQL span outputs are the same."""
    def norm(df: pd.DataFrame) -> pd.DataFrame:
        out = df[["member_id", "plan_id", "span_eff", "span_term", "segment_count"]].copy()
        for col in ("span_eff", "span_term"):
            out[col] = out[col].astype(str).str[:10]  # compare as YYYY-MM-DD
        out["segment_count"] = out["segment_count"].astype(int)
        return out.sort_values(["member_id", "plan_id", "span_eff"]).reset_index(drop=True)

    return norm(py).equals(norm(sql))


def main() -> None:
    raw = load_segments(DATA)
    clean, stats = clean_segments(raw)
    spans = consolidate_spans(clean)
    gaps = find_gaps(spans)
    ce = continuous_enrollment(spans)
    sql_spans = run_sql(DATA)

    OUT.mkdir(exist_ok=True)
    spans.to_csv(OUT / "coverage_spans.csv", index=False)
    gaps.to_csv(OUT / "coverage_gaps.csv", index=False)
    ce.to_csv(OUT / "continuous_enrollment_2025.csv", index=False)

    print("== Load ==")
    for k, v in stats.items():
        print(f"  {k:<16} {v:>6,}")
    print("\n== Consolidation ==")
    print(f"  members          {spans['member_id'].nunique():>6,}")
    print(f"  clean segments   {stats['clean_rows']:>6,}")
    print(f"  coverage spans   {len(spans):>6,}")
    print(f"  reduction        {1 - len(spans) / stats['clean_rows']:>6.1%}")
    print(f"  gaps found       {len(gaps):>6,}")
    print(f"  SQL == Python    {spans_match(spans, sql_spans)!s:>6}")
    print("\n== HEDIS continuous enrollment, MY2025 (<=1 gap of <=45 days, enrolled 12/31) ==")
    rate = ce["continuously_enrolled"].mean()
    print(f"  eligible members {int(ce['continuously_enrolled'].sum()):>6,} of {len(ce):,} ({rate:.1%})")
    for reason, n in ce["reason"].value_counts().items():
        print(f"  {reason:<28} {n:>5,}")


if __name__ == "__main__":
    main()
