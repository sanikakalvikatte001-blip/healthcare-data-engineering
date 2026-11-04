-- =============================================================================
-- marts.dim_provider — SCD Type 2 provider dimension
--
--   provider_sk     surrogate key, stable hash of (npi, effective_from) so keys
--                   do not shift when a new provider is added on rebuild
--   npi             durable / natural key (join here for "as-current" views)
--   Type 2 columns  taxonomy_code, specialty_desc, network_status, group_tin,
--                   roster_status
--   Type 1 columns  provider name (latest value applied to every version)
--   provider_sk = -1 is the "Unknown provider" member for unmatched NPIs
--   PRE_ROSTER rows: inferred versions for providers who joined the roster
--                   after history starts (late credentialing). They cover
--                   1900-01-01 .. first file - 1 day, so claims with an
--                   earlier DOS still get a point-in-time key and are NOT
--                   reported as in-network.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS marts;

CREATE OR REPLACE TABLE marts.dim_provider AS
WITH latest_name AS (
    SELECT npi,
           arg_max(provider_last_name,  snapshot_date) AS provider_last_name,
           arg_max(provider_first_name, snapshot_date) AS provider_first_name
    FROM staging.stg_provider_roster
    GROUP BY npi
),
history_start AS (
    SELECT min(effective_from) AS first_snapshot FROM intermediate.int_provider_versions
),
pre_roster AS (
    -- one inferred version per provider whose first file is after history start
    SELECT v.npi,
           0                                   AS version_no,
           v.taxonomy_code, v.specialty_desc,
           'NOT_ON_ROSTER'                     AS network_status,
           v.group_tin,
           'PRE_ROSTER'                        AS roster_status,
           DATE '1900-01-01'                   AS effective_from,
           (v.effective_from - INTERVAL 1 DAY)::DATE AS effective_to,
           FALSE                               AS is_current,
           NULL::VARCHAR                       AS attr_hash
    FROM intermediate.int_provider_versions v, history_start h
    WHERE v.version_no = 1 AND v.effective_from > h.first_snapshot
),
all_versions AS (
    SELECT npi, version_no, taxonomy_code, specialty_desc, network_status,
           group_tin, roster_status, effective_from, effective_to, is_current,
           attr_hash
    FROM intermediate.int_provider_versions
    UNION ALL
    SELECT * FROM pre_roster
)
SELECT
    -1::BIGINT              AS provider_sk,
    'UNKNOWN'               AS npi,
    0                       AS version_no,
    'UNKNOWN'               AS provider_last_name,
    'UNKNOWN'               AS provider_first_name,
    'UNKNOWN'               AS taxonomy_code,
    'Unknown'               AS specialty_desc,
    'UNKNOWN'               AS network_status,
    'UNKNOWN'               AS group_tin,
    'UNKNOWN'               AS roster_status,
    DATE '1900-01-01'       AS effective_from,
    DATE '9999-12-31'       AS effective_to,
    TRUE                    AS is_current,
    NULL::VARCHAR           AS attr_hash
UNION ALL
SELECT
    ('0x' || left(md5(v.npi || '|' || v.effective_from::VARCHAR), 15))::BIGINT,
    v.npi,
    v.version_no::INTEGER,
    n.provider_last_name,
    n.provider_first_name,
    v.taxonomy_code,
    v.specialty_desc,
    v.network_status,
    v.group_tin,
    v.roster_status,
    v.effective_from,
    v.effective_to,
    v.is_current,
    v.attr_hash
FROM all_versions v
JOIN latest_name n USING (npi);
