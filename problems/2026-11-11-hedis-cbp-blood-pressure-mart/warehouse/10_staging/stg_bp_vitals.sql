-- =============================================================================
-- 10_staging / stg_bp_vital
-- Grain: one row per raw EHR vital row (nothing is dropped here - invalid rows
-- are flagged, and routed to an exception table in the marts layer).
-- Parsing: prefer discrete systolic/diastolic columns; otherwise extract
-- "SSS/DDD" from free text ("138 / 88 mmHg", "152/94").
-- Validation: both parts present, systolic 60-300, diastolic 30-200, and
-- systolic > diastolic (catches swapped entries such as "78/136").
-- =============================================================================
CREATE OR REPLACE TABLE stg.bp_vital AS
WITH parsed AS (
    SELECT
        vital_id,
        trim(member_id)                                  AS member_id,
        upper(trim(encounter_setting))                   AS encounter_setting,
        taken_at::TIMESTAMP                              AS taken_at,
        taken_at::TIMESTAMP::DATE                        AS reading_date,
        bp_text,
        coalesce(try_cast(systolic AS INT),
                 try_cast(regexp_extract(bp_text, '(\d{1,3})\s*/\s*(\d{1,3})', 1) AS INT))  AS systolic,
        coalesce(try_cast(diastolic AS INT),
                 try_cast(regexp_extract(bp_text, '(\d{1,3})\s*/\s*(\d{1,3})', 2) AS INT))  AS diastolic
    FROM raw.ehr_vitals
)
SELECT
    *,
    CASE
        WHEN systolic IS NULL OR diastolic IS NULL      THEN 'UNPARSEABLE'
        WHEN systolic NOT BETWEEN 60 AND 300
          OR diastolic NOT BETWEEN 30 AND 200           THEN 'OUT_OF_RANGE'
        WHEN systolic <= diastolic                      THEN 'SYSTOLIC_NOT_ABOVE_DIASTOLIC'
    END                                                 AS reject_reason,
    reject_reason IS NULL                               AS is_valid
FROM parsed;
