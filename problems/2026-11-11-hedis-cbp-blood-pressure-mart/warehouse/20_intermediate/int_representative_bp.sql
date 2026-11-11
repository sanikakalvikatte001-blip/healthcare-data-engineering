-- =============================================================================
-- 20_intermediate / int_representative_bp
-- Grain: one row per member that has a usable BP in the measurement year.
-- HEDIS CBP rule: use the most recent date of service with a BP; when several
-- readings exist that day, take the LOWEST systolic and the LOWEST diastolic
-- (they may come from different readings). A date only qualifies when both
-- components are present.
-- =============================================================================
CREATE OR REPLACE TABLE int.representative_bp AS
WITH p AS (SELECT * FROM ref.cbp_params),
per_day AS (
    SELECT member_id,
           reading_date,
           min(systolic)                         AS systolic,
           min(diastolic)                        AS diastolic,
           count(*)                              AS readings_on_date,
           string_agg(DISTINCT source_system, '+' ORDER BY source_system) AS sources
    FROM int.bp_reading
    WHERE counts_for_cbp
    GROUP BY member_id, reading_date
    HAVING min(systolic) IS NOT NULL AND min(diastolic) IS NOT NULL
)
SELECT d.*,
       d.systolic  < p.systolic_threshold
   AND d.diastolic < p.diastolic_threshold       AS is_controlled
FROM per_day d
CROSS JOIN p
QUALIFY row_number() OVER (PARTITION BY d.member_id ORDER BY d.reading_date DESC) = 1;
