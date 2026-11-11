-- =============================================================================
-- 30_marts / fct_bp_reading  +  dq_bp_reject
-- fct_bp_reading grain: one row per BP observation (EHR vital row, or one
-- claim's CPT II codes). member_sk is resolved POINT-IN-TIME: the dimension
-- version that was valid on the reading date, so a reading taken while the
-- member was on Medicaid stays attributed to the Medicaid version.
-- Readings dated before the member's first coverage version (the EHR knew the
-- patient before they joined the plan) fall back to the FIRST version and are
-- flagged member_version_match = 'BEFORE_FIRST_VERSION' - they still count for
-- CBP, because the measure checks enrollment separately, not per reading.
-- dq_bp_reject: EHR rows that failed parsing/validation, kept for the source
-- team instead of being silently dropped.
-- =============================================================================
CREATE OR REPLACE TABLE mart.fct_bp_reading AS
SELECT
    r.source_system,
    r.source_id,
    r.member_id,
    coalesce(d.member_sk, f.member_sk)       AS member_sk,
    CASE WHEN d.member_sk IS NOT NULL THEN 'POINT_IN_TIME'
         ELSE 'BEFORE_FIRST_VERSION' END     AS member_version_match,
    strftime(r.reading_date, '%Y%m%d')::INT  AS reading_date_key,
    r.reading_date,
    r.setting,
    r.systolic,
    r.diastolic,
    r.is_acute_setting,
    r.counts_for_cbp
FROM int.bp_reading r
LEFT JOIN mart.dim_member d
       ON d.member_id = r.member_id
      AND r.reading_date BETWEEN d.valid_from AND d.valid_to
LEFT JOIN mart.dim_member f
       ON f.member_id = r.member_id
      AND f.version_no = 1;

CREATE OR REPLACE TABLE mart.dq_bp_reject AS
SELECT vital_id, member_id, encounter_setting, taken_at, bp_text,
       systolic AS parsed_systolic, diastolic AS parsed_diastolic, reject_reason
FROM stg.bp_vital
WHERE NOT is_valid;
