-- =============================================================================
-- staging.stg_members  — light typing / trimming of the member header
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS staging;

CREATE OR REPLACE VIEW staging.stg_members AS
SELECT
    trim(member_id)               AS member_id,
    birth_date::DATE              AS birth_date,
    upper(trim(gender))           AS gender,
    upper(trim(line_of_business)) AS line_of_business
FROM raw.member;
