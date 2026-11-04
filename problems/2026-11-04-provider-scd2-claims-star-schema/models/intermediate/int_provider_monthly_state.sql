-- =============================================================================
-- intermediate.int_provider_monthly_state
-- A dense provider x snapshot_date grid from the provider's first file through
-- the latest file we have, so "missing from a file" is handled explicitly:
--
--   * provider absent for a month but seen again later -> feed gap, carry the
--     previous month's attributes forward (roster_status stays ACTIVE)
--   * provider absent and NEVER seen again          -> roster_status INACTIVE
--     (termed on the first missing snapshot date; network_status = TERMED)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS intermediate;

CREATE OR REPLACE TABLE intermediate.int_provider_monthly_state AS
WITH snapshot_dates AS (
    SELECT DISTINCT snapshot_date FROM staging.stg_provider_roster
),
provider_bounds AS (
    SELECT npi,
           min(snapshot_date) AS first_seen,
           max(snapshot_date) AS last_seen
    FROM staging.stg_provider_roster
    GROUP BY npi
),
grid AS (
    SELECT b.npi, d.snapshot_date, b.last_seen
    FROM provider_bounds b
    JOIN snapshot_dates d ON d.snapshot_date >= b.first_seen
),
joined AS (
    SELECT g.npi, g.snapshot_date, g.last_seen,
           s.snapshot_date IS NOT NULL AS present_in_file,
           s.taxonomy_code, s.specialty_desc, s.network_status, s.group_tin
    FROM grid g
    LEFT JOIN staging.stg_provider_roster s
           ON s.npi = g.npi AND s.snapshot_date = g.snapshot_date
),
filled AS (
    SELECT
        npi, snapshot_date, present_in_file,
        -- carry last known attributes forward across missing months
        last_value(taxonomy_code  IGNORE NULLS) OVER w AS taxonomy_code,
        last_value(specialty_desc IGNORE NULLS) OVER w AS specialty_desc,
        -- a termed provider is never in network, whatever the last file said
        CASE WHEN snapshot_date > last_seen THEN 'TERMED'
             ELSE last_value(network_status IGNORE NULLS) OVER w
        END                                            AS network_status,
        last_value(group_tin      IGNORE NULLS) OVER w AS group_tin,
        CASE WHEN snapshot_date > last_seen THEN 'INACTIVE' ELSE 'ACTIVE' END
                                                       AS roster_status
    FROM joined
    WINDOW w AS (PARTITION BY npi ORDER BY snapshot_date
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
)
SELECT
    *,
    CASE WHEN NOT present_in_file AND roster_status = 'ACTIVE'
         THEN TRUE ELSE FALSE END                                  AS is_gap_filled,
    md5(concat_ws('|', taxonomy_code, network_status, group_tin, roster_status))
                                                                   AS attr_hash
FROM filled;
