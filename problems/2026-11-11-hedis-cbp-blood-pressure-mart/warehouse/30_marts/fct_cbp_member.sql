-- =============================================================================
-- 30_marts / fct_cbp_member
-- Grain: one row per member with coverage in the measurement year.
-- Every member gets exactly one outcome, evaluated in this order:
--   NOT_ELIGIBLE_AGE         age (as of Dec 31) outside min_age..max_age
--   NOT_ELIGIBLE_ENROLLMENT  fails continuous enrollment
--   NOT_IN_DENOMINATOR_HTN   < 2 distinct HTN visit dates in the window
--   EXCL_*                   required exclusion (first match by priority)
--   NUMERATOR                representative BP < 140/90
--   GAP_UNCONTROLLED         representative BP >= 140 or >= 90
--   GAP_NO_READING           no usable BP in the measurement year
-- product_line / pcp_npi come from the dim_member version valid on Dec 31
-- (HEDIS reports a member under the product line held at the end of the MY).
-- =============================================================================
CREATE OR REPLACE TABLE mart.fct_cbp_member AS
WITH p AS (SELECT * FROM ref.cbp_params),
ex AS (
    SELECT member_id,
           bool_or(exclusion_category = 'HOSPICE')          AS has_hospice,
           bool_or(exclusion_category = 'PALLIATIVE_CARE')  AS has_palliative,
           bool_or(exclusion_category = 'ESRD')             AS has_esrd,
           bool_or(exclusion_category = 'PREGNANCY')        AS has_pregnancy,
           bool_or(exclusion_category = 'FRAILTY')          AS has_frailty,
           bool_or(exclusion_category = 'ADVANCED_ILLNESS') AS has_advanced_illness
    FROM int.exclusion_event
    GROUP BY member_id
),
-- dimension version valid on Dec 31 of the MY; falls back to the latest
-- version that started before then (member not enrolled on Dec 31 -> fails CE)
dim_at_my_end AS (
    SELECT dm.*
    FROM mart.dim_member dm, p
    WHERE dm.valid_from <= p.my_end
    QUALIFY row_number() OVER (PARTITION BY dm.member_id ORDER BY dm.valid_from DESC) = 1
),
base AS (
    SELECT
        e.member_id,
        p.measure_id,
        p.my                                              AS measurement_year,
        d.member_sk                                       AS member_sk_at_my_end,
        d.product_line,
        d.pcp_npi,
        d.gender,
        -- exact age on Dec 31 of the MY
        date_diff('year', d.birth_date, p.my_end)
          - CASE WHEN strftime(p.my_end, '%m%d') < strftime(d.birth_date, '%m%d') THEN 1 ELSE 0 END
                                                          AS age_at_my_end,
        e.is_continuously_enrolled,
        e.gap_count,
        e.longest_gap_days,
        coalesce(h.htn_visit_dates, 0)                    AS htn_visit_dates,
        coalesce(h.meets_htn_event, FALSE)                AS meets_htn_event,
        coalesce(x.has_hospice, FALSE)                    AS has_hospice,
        coalesce(x.has_palliative, FALSE)                 AS has_palliative,
        coalesce(x.has_esrd, FALSE)                       AS has_esrd,
        coalesce(x.has_pregnancy, FALSE)                  AS has_pregnancy,
        coalesce(x.has_frailty, FALSE)                    AS has_frailty,
        coalesce(x.has_advanced_illness, FALSE)           AS has_advanced_illness,
        b.reading_date                                    AS rep_bp_date,
        b.systolic                                        AS rep_systolic,
        b.diastolic                                       AS rep_diastolic,
        b.sources                                         AS rep_bp_sources,
        b.is_controlled
    FROM int.enrollment_my e
    CROSS JOIN p
    JOIN dim_at_my_end d ON d.member_id = e.member_id
    LEFT JOIN int.htn_visit h        ON h.member_id = e.member_id
    LEFT JOIN ex x                   ON x.member_id = e.member_id
    LEFT JOIN int.representative_bp b ON b.member_id = e.member_id
)
SELECT
    base.*,
    CASE
        WHEN has_hospice                                              THEN 'EXCL_HOSPICE'
        WHEN has_palliative                                           THEN 'EXCL_PALLIATIVE_CARE'
        WHEN has_esrd                                                 THEN 'EXCL_ESRD'
        WHEN has_pregnancy                                            THEN 'EXCL_PREGNANCY'
        WHEN age_at_my_end >= p.frailty_only_min_age AND has_frailty  THEN 'EXCL_FRAILTY_81_PLUS'
        WHEN age_at_my_end >= p.frailty_adv_illness_min_age
         AND has_frailty AND has_advanced_illness                     THEN 'EXCL_FRAILTY_ADVANCED_ILLNESS'
    END                                                               AS exclusion_reason,
    age_at_my_end BETWEEN p.min_age AND p.max_age
      AND is_continuously_enrolled AND meets_htn_event                AS in_eligible_population,
    in_eligible_population AND exclusion_reason IS NULL               AS in_denominator,
    in_denominator AND coalesce(is_controlled, FALSE)                 AS in_numerator,
    CASE
        WHEN age_at_my_end NOT BETWEEN p.min_age AND p.max_age        THEN 'NOT_ELIGIBLE_AGE'
        WHEN NOT is_continuously_enrolled                             THEN 'NOT_ELIGIBLE_ENROLLMENT'
        WHEN NOT meets_htn_event                                      THEN 'NOT_IN_DENOMINATOR_HTN'
        WHEN exclusion_reason IS NOT NULL                             THEN exclusion_reason
        WHEN is_controlled                                            THEN 'NUMERATOR'
        WHEN rep_bp_date IS NOT NULL                                  THEN 'GAP_UNCONTROLLED'
        ELSE 'GAP_NO_READING'
    END                                                               AS outcome
FROM base
CROSS JOIN p;
