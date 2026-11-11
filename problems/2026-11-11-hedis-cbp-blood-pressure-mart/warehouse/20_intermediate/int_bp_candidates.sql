-- =============================================================================
-- 20_intermediate / int_bp_reading
-- Grain: one row per blood-pressure observation from either source:
--   * EHR vitals (valid rows only)  -> exact systolic / diastolic
--   * CPT II codes on claims         -> band mapped to a representative value
--     (3074F -> 129, 3075F -> 139, 3077F -> 140, 3078F -> 79, ...); one claim
--     may carry only one component, which is fine - components are combined
--     per date in int_representative_bp.
-- counts_for_cbp is FALSE for readings taken in the ED / inpatient (EHR
-- setting or claim place of service) or outside the measurement year.
-- =============================================================================
CREATE OR REPLACE TABLE int.bp_reading AS
WITH p AS (SELECT * FROM ref.cbp_params),
ehr AS (
    SELECT 'EHR'               AS source_system,
           vital_id            AS source_id,
           member_id,
           reading_date,
           encounter_setting   AS setting,
           systolic,
           diastolic,
           encounter_setting IN ('ED', 'INPATIENT') AS is_acute_setting
    FROM stg.bp_vital
    WHERE is_valid
),
cpt2 AS (
    SELECT 'CLAIM_CPT2'                     AS source_system,
           cl.claim_id                      AS source_id,
           cl.member_id,
           cl.dos                           AS reading_date,
           'POS-' || any_value(cl.pos_code) AS setting,
           min(CASE WHEN b.component = 'SYSTOLIC'  THEN b.representative_value END) AS systolic,
           min(CASE WHEN b.component = 'DIASTOLIC' THEN b.representative_value END) AS diastolic,
           bool_or(cl.pos_code IN (SELECT code FROM ref.value_set WHERE value_set = 'ACUTE_OR_ED_POS'))
                                            AS is_acute_setting
    FROM stg.claim_line cl
    JOIN ref.cpt2_bp_code b ON b.code = cl.proc_code
    GROUP BY cl.claim_id, cl.member_id, cl.dos
)
SELECT r.*,
       r.reading_date BETWEEN p.my_start AND p.my_end AND NOT r.is_acute_setting AS counts_for_cbp
FROM (SELECT * FROM ehr UNION ALL SELECT * FROM cpt2) r
CROSS JOIN p;
