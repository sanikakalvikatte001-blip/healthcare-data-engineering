-- =============================================================================
-- 20_intermediate / int_enrollment_my
-- Grain: one row per member with any coverage in the measurement year.
-- Continuous enrollment (CE) rule: enrolled on Dec 31 of the MY, and no more
-- than <ce_max_gaps> gap(s) of at most <ce_max_gap_days> days during the MY.
--
-- Steps (classic gaps-and-islands):
--   1. clip each segment to the MY
--   2. merge overlapping / adjacent segments into islands
--   3. derive gaps between islands, plus a leading gap (MY start -> first
--      island) and a trailing gap (last island -> MY end)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS int;

CREATE OR REPLACE TABLE int.enrollment_my AS
WITH p AS (SELECT * FROM ref.cbp_params),
clipped AS (
    SELECT c.member_id,
           greatest(c.eff_date,  p.my_start) AS seg_start,
           least(c.term_date,    p.my_end)   AS seg_end
    FROM stg.member_coverage c, p
    WHERE c.eff_date <= p.my_end AND c.term_date >= p.my_start
),
flagged AS (
    -- a segment starts a new island when it begins after every earlier
    -- segment has ended (+1 day: adjacent segments are contiguous)
    SELECT *,
           CASE WHEN seg_start <= max(seg_end) OVER w_prev + 1 THEN 0 ELSE 1 END AS is_new_island
    FROM clipped
    WINDOW w_prev AS (PARTITION BY member_id ORDER BY seg_start, seg_end
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),
islands AS (
    SELECT member_id, island_no, min(seg_start) AS island_start, max(seg_end) AS island_end
    FROM (SELECT *, sum(is_new_island) OVER (PARTITION BY member_id ORDER BY seg_start, seg_end) AS island_no
          FROM flagged)
    GROUP BY member_id, island_no
),
gaps AS (
    -- interior gaps
    SELECT member_id,
           island_start - lag(island_end) OVER (PARTITION BY member_id ORDER BY island_start) - 1 AS gap_days
    FROM islands
    UNION ALL   -- leading gap
    SELECT i.member_id, min(i.island_start) - p.my_start
    FROM islands i, p GROUP BY i.member_id, p.my_start
    UNION ALL   -- trailing gap
    SELECT i.member_id, p.my_end - max(i.island_end)
    FROM islands i, p GROUP BY i.member_id, p.my_end
),
gap_summary AS (
    SELECT member_id,
           count(*) FILTER (WHERE gap_days > 0)                    AS gap_count,
           coalesce(max(gap_days) FILTER (WHERE gap_days > 0), 0)  AS longest_gap_days
    FROM gaps
    GROUP BY member_id
),
island_summary AS (
    SELECT i.member_id,
           count(*)                                AS enrollment_islands,
           sum(i.island_end - i.island_start + 1)::INT AS enrolled_days,
           bool_or(i.island_end = p.my_end)        AS enrolled_on_my_end
    FROM islands i, p
    GROUP BY i.member_id
)
SELECT s.member_id,
       s.enrollment_islands,
       s.enrolled_days,
       g.gap_count,
       g.longest_gap_days,
       s.enrolled_on_my_end,
       s.enrolled_on_my_end
         AND g.gap_count        <= p.ce_max_gaps
         AND g.longest_gap_days <= p.ce_max_gap_days   AS is_continuously_enrolled
FROM island_summary s
JOIN gap_summary g USING (member_id)
CROSS JOIN p;
