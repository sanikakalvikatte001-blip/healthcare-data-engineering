-- =============================================================================
-- marts.dim_member — Type 1 member dimension (kept simple on purpose; the
-- focus of this project is the Type 2 provider dimension).
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS marts;

CREATE OR REPLACE TABLE marts.dim_member AS
SELECT
    -1::BIGINT          AS member_sk,
    'UNKNOWN'           AS member_id,
    NULL::DATE          AS birth_date,
    'U'                 AS gender,
    'UNKNOWN'           AS line_of_business
UNION ALL
SELECT
    ('0x' || left(md5(member_id), 15))::BIGINT  AS member_sk,  -- stable hash key
    member_id, birth_date, gender, line_of_business
FROM staging.stg_members;
