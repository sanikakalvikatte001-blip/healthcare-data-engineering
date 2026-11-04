-- =============================================================================
-- staging.stg_provider_roster
-- One clean row per (snapshot_date, npi).
--   * trims / upper-cases text so cosmetic differences never look like changes
--   * keeps only the LATEST delivery of a snapshot_date (re-delivered files)
--   * removes exact duplicate rows inside a single file
--   * computes attr_hash over the Type 2 tracked attributes only
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS staging;

CREATE OR REPLACE VIEW staging.stg_provider_roster AS
WITH cleaned AS (
    SELECT
        snapshot_date,
        load_ts,
        trim(npi)                                   AS npi,
        upper(trim(provider_last_name))             AS provider_last_name,
        upper(trim(provider_first_name))            AS provider_first_name,
        upper(trim(taxonomy_code))                  AS taxonomy_code,
        trim(specialty_desc)                        AS specialty_desc,
        upper(trim(network_status))                 AS network_status,
        trim(group_tin)                             AS group_tin
    FROM raw.provider_roster_snapshot
),
ranked AS (
    SELECT
        *,
        -- latest file for a snapshot_date wins; ties (exact dupes) collapse to 1
        row_number() OVER (
            PARTITION BY snapshot_date, npi
            ORDER BY load_ts DESC
        ) AS rn
    FROM cleaned
)
SELECT
    snapshot_date,
    load_ts,
    npi,
    provider_last_name,
    provider_first_name,
    taxonomy_code,
    specialty_desc,
    network_status,
    group_tin,
    -- Type 2 tracked attributes. Name is Type 1 (overwrite) on purpose:
    -- a typo fix should not split a provider's history.
    md5(concat_ws('|', taxonomy_code, network_status, group_tin)) AS attr_hash
FROM ranked
WHERE rn = 1;
