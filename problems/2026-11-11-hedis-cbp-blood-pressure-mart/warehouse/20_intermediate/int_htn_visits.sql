-- =============================================================================
-- 20_intermediate / int_htn_visit
-- Grain: one row per member with >= 1 qualifying hypertension visit.
-- A qualifying visit = an outpatient or telephone/online E/M procedure, not in
-- an inpatient/ED place of service, with an Essential Hypertension diagnosis
-- on the same claim line, inside the HTN window (Jan 1 of the prior year
-- through Jun 30 of the MY). The denominator needs N *distinct dates*, so
-- duplicate claims on the same day count once.
-- =============================================================================
CREATE OR REPLACE TABLE int.htn_visit AS
WITH p AS (SELECT * FROM ref.cbp_params),
visit_lines AS (
    SELECT DISTINCT cc.claim_id, cc.line_no, cc.member_id, cc.dos
    FROM stg.claim_code cc
    JOIN ref.value_set vs
      ON vs.code_system = cc.code_system AND vs.code = cc.code
     AND vs.value_set IN ('OUTPATIENT_VISIT', 'TELEPHONE_ONLINE')
    WHERE cc.pos_code NOT IN (SELECT code FROM ref.value_set WHERE value_set = 'ACUTE_OR_ED_POS')
),
htn_lines AS (
    SELECT DISTINCT cc.claim_id, cc.line_no
    FROM stg.claim_code cc
    JOIN ref.value_set vs
      ON vs.code_system = cc.code_system AND vs.code = cc.code AND vs.value_set = 'HYPERTENSION'
)
SELECT
    v.member_id,
    count(DISTINCT v.dos)                         AS htn_visit_dates,
    min(v.dos)                                    AS first_htn_visit,
    max(v.dos)                                    AS last_htn_visit,
    count(DISTINCT v.dos) >= any_value(p.min_htn_visit_dates) AS meets_htn_event
FROM visit_lines v
JOIN htn_lines h USING (claim_id, line_no)
CROSS JOIN p
WHERE v.dos BETWEEN p.htn_window_start AND p.htn_window_end
GROUP BY v.member_id;
