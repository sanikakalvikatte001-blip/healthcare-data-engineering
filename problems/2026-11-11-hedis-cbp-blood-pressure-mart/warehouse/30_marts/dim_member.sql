-- =============================================================================
-- 30_marts / dim_member  (SCD Type 2)
-- Grain: one row per member per version of the tracked attributes
--        (product_line, pcp_npi). birth_date / gender are Type 1 (latest wins).
-- Built from coverage segments: consecutive segments with identical tracked
-- attributes collapse into one version (a pure enrollment gap is NOT a new
-- version - gaps live in int.enrollment_my). Versions are contiguous:
-- valid_to = next version's valid_from - 1, the last one is open-ended.
-- member_sk is a deterministic hash so keys are stable across rebuilds.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS mart;

CREATE OR REPLACE TABLE mart.dim_member AS
WITH seg AS (
    SELECT member_id, product_line, pcp_npi, eff_date,
           -- start a new version whenever a tracked attribute changes
           CASE WHEN (product_line, pcp_npi) IS NOT DISTINCT FROM
                     lag((product_line, pcp_npi)) OVER (PARTITION BY member_id ORDER BY eff_date)
                THEN 0 ELSE 1 END AS is_change
    FROM stg.member_coverage
),
versioned AS (
    SELECT *, sum(is_change) OVER (PARTITION BY member_id ORDER BY eff_date) AS version_no
    FROM seg
),
versions AS (
    SELECT member_id, version_no::INT AS version_no,
           any_value(product_line) AS product_line,
           any_value(pcp_npi)      AS pcp_npi,
           min(eff_date)           AS valid_from
    FROM versioned
    GROUP BY member_id, version_no
),
type1 AS (   -- latest demographic values per member
    SELECT member_id, birth_date, gender
    FROM stg.member_coverage
    QUALIFY row_number() OVER (PARTITION BY member_id ORDER BY source_file_date DESC, eff_date DESC) = 1
)
SELECT
    md5(v.member_id || '|' || v.valid_from)::VARCHAR                     AS member_sk,
    v.member_id,
    v.version_no,
    t.birth_date,
    t.gender,
    v.product_line,
    v.pcp_npi,
    v.valid_from,
    coalesce(lead(v.valid_from) OVER w - 1, DATE '9999-12-31')           AS valid_to,
    lead(v.valid_from) OVER w IS NULL                                    AS is_current
FROM versions v
JOIN type1 t USING (member_id)
WINDOW w AS (PARTITION BY v.member_id ORDER BY v.valid_from);
