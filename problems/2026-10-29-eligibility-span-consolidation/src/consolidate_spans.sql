-- Consolidate eligibility segments into continuous coverage spans (gaps and islands).
-- Written for DuckDB, but the window-function pattern works in SQL Server,
-- Snowflake, Postgres and most warehouses with small syntax changes.
--
-- Input:  table `segments` (member_id, plan_id, eff_date DATE, term_date DATE)
-- Dates are inclusive. Touching segments (term 01-31, eff 02-01) are merged.

WITH clean AS (
    -- Drop bad rows and exact duplicates (e.g. the same 834 loaded twice).
    SELECT DISTINCT member_id, plan_id, eff_date, term_date
    FROM segments
    WHERE term_date >= eff_date
),
ordered AS (
    -- Latest term date seen so far, BEFORE this row. A running max (not LAG)
    -- handles one long segment that covers several shorter ones.
    SELECT
        *,
        MAX(term_date) OVER (
            PARTITION BY member_id, plan_id
            ORDER BY eff_date, term_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prev_max_term
    FROM clean
),
flagged AS (
    SELECT
        *,
        CASE
            WHEN prev_max_term IS NULL THEN 1
            WHEN eff_date > prev_max_term + 1 THEN 1   -- a real break in coverage
            ELSE 0
        END AS new_island
    FROM ordered
),
islands AS (
    SELECT
        *,
        SUM(new_island) OVER (
            PARTITION BY member_id, plan_id
            ORDER BY eff_date, term_date
            ROWS UNBOUNDED PRECEDING
        ) AS island_id
    FROM flagged
)
SELECT
    member_id,
    plan_id,
    MIN(eff_date)  AS span_eff,
    MAX(term_date) AS span_term,
    COUNT(*)       AS segment_count
FROM islands
GROUP BY member_id, plan_id, island_id
ORDER BY member_id, plan_id, span_eff;
