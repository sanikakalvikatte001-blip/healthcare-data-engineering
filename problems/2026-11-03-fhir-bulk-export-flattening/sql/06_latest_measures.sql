-- =============================================================================
-- 06_latest_measures.sql : a small downstream mart built on observation_flat.
-- Latest numeric value per patient for common vitals/labs, pivoted wide -
-- the shape care-gap and quality-measure logic (e.g. CBP, HbA1c control) needs.
-- =============================================================================

CREATE OR REPLACE TEMP VIEW patient_latest_measures AS
WITH ranked AS (
    SELECT patient_id, loinc_code, value_numeric,
           ROW_NUMBER() OVER (PARTITION BY patient_id, loinc_code
                              ORDER BY effective_ts DESC, observation_id) AS rn
    FROM observation_flat
    WHERE value_type = 'Quantity'
)
SELECT *
FROM (SELECT patient_id, loinc_code, value_numeric FROM ranked WHERE rn = 1)
PIVOT (
    first(value_numeric) FOR loinc_code IN (
        '8480-6'  AS systolic_bp,
        '8462-4'  AS diastolic_bp,
        '8867-4'  AS heart_rate,
        '29463-7' AS weight_kg,
        '4548-4'  AS hba1c_pct
    )
);
