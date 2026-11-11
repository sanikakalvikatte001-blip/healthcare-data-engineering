-- =============================================================================
-- 30_marts / mart_cbp_care_gap
-- Grain: one row per open care gap (denominator member not in numerator) -
-- the worklist a care-management team or PCP office would act on.
-- Includes the last BP the plan knows about (even if it didn't count, e.g. an
-- ED reading) so outreach staff have context, and a simple priority.
-- =============================================================================
CREATE OR REPLACE TABLE mart.cbp_care_gap AS
WITH last_any AS (
    SELECT member_id, reading_date, systolic, diastolic, setting
    FROM mart.fct_bp_reading
    WHERE systolic IS NOT NULL AND diastolic IS NOT NULL
    QUALIFY row_number() OVER (PARTITION BY member_id ORDER BY reading_date DESC, systolic DESC) = 1
)
SELECT
    f.member_id,
    f.product_line,
    f.pcp_npi,
    f.age_at_my_end,
    f.outcome                                         AS gap_type,
    f.rep_bp_date,
    f.rep_systolic,
    f.rep_diastolic,
    l.reading_date                                    AS last_any_bp_date,
    l.systolic || '/' || l.diastolic                  AS last_any_bp,
    l.setting                                         AS last_any_bp_setting,
    CASE
        WHEN f.rep_systolic >= 160 OR f.rep_diastolic >= 100 THEN 1   -- stage 2 range
        WHEN f.outcome = 'GAP_NO_READING'                    THEN 2   -- never measured
        ELSE 3
    END                                               AS outreach_priority
FROM mart.fct_cbp_member f
LEFT JOIN last_any l USING (member_id)
WHERE f.in_denominator AND NOT f.in_numerator
ORDER BY outreach_priority, f.pcp_npi, f.member_id;
