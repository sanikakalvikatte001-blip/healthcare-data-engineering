-- =============================================================================
-- intermediate.int_provider_versions
-- Collapses the monthly grid into SCD Type 2 versions with gaps-and-islands.
--
-- Why not GROUP BY the attributes? A provider who goes IN -> OUT -> IN would
-- get its two IN periods merged into one row spanning the OUT period, which
-- silently mis-attributes claims. Instead we flag every month whose attr_hash
-- differs from the previous month and use a running sum as the version number.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS intermediate;

CREATE OR REPLACE TABLE intermediate.int_provider_versions AS
WITH flagged AS (
    SELECT
        *,
        CASE WHEN attr_hash IS DISTINCT FROM
                  lag(attr_hash) OVER (PARTITION BY npi ORDER BY snapshot_date)
             THEN 1 ELSE 0 END AS is_change
    FROM intermediate.int_provider_monthly_state
),
islands AS (
    SELECT
        *,
        sum(is_change) OVER (PARTITION BY npi ORDER BY snapshot_date
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            AS version_no
    FROM flagged
),
versions AS (
    SELECT
        npi,
        version_no,
        min(snapshot_date)            AS effective_from,
        any_value(taxonomy_code)      AS taxonomy_code,
        any_value(specialty_desc)     AS specialty_desc,
        any_value(network_status)     AS network_status,
        any_value(group_tin)          AS group_tin,
        any_value(roster_status)      AS roster_status,
        any_value(attr_hash)          AS attr_hash,
        count(*)                      AS months_in_version,
        sum(is_gap_filled::INT)       AS gap_filled_months
    FROM islands
    GROUP BY npi, version_no
)
SELECT
    *,
    -- half-open logic expressed as an inclusive end date for BI friendliness
    coalesce(
        lead(effective_from) OVER (PARTITION BY npi ORDER BY effective_from)
            - INTERVAL 1 DAY,
        DATE '9999-12-31')::DATE                                 AS effective_to,
    lead(effective_from) OVER (PARTITION BY npi ORDER BY effective_from) IS NULL
                                                                 AS is_current
FROM versions;
