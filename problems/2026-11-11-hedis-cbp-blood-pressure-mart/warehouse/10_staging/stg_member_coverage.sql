-- =============================================================================
-- 10_staging / stg_member_coverage
-- Grain: one row per (member_id, eff_date) coverage segment.
-- * Casts YYYYMMDD strings to DATE; blank term date -> 9999-12-31 (open).
-- * The eligibility feed resends segments in later files. For the same
--   (member, eff_date) we keep the row from the most recent file, which also
--   lets a corrected resend supersede a bad one.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS stg;

CREATE OR REPLACE TABLE stg.member_coverage AS
SELECT
    trim(member_id)                                         AS member_id,
    strptime(birth_date, '%Y%m%d')::DATE                    AS birth_date,
    upper(trim(gender))                                     AS gender,
    upper(trim(product_line))                               AS product_line,
    trim(pcp_npi)                                           AS pcp_npi,
    strptime(eff_date, '%Y%m%d')::DATE                      AS eff_date,
    coalesce(strptime(nullif(trim(term_date), ''), '%Y%m%d')::DATE,
             DATE '9999-12-31')                             AS term_date,
    strptime(source_file_date, '%Y%m%d')::DATE              AS source_file_date
FROM raw.member_coverage
QUALIFY row_number() OVER (
    PARTITION BY trim(member_id), eff_date
    ORDER BY source_file_date DESC
) = 1;
