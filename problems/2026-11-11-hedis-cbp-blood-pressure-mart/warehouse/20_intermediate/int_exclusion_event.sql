-- =============================================================================
-- 20_intermediate / int_exclusion_event
-- Grain: one row per (member, exclusion_category) with the first qualifying
-- date. Each value set has its own look-back window:
--   HOSPICE, PALLIATIVE_CARE, PREGNANCY, FRAILTY -> measurement year
--   ADVANCED_ILLNESS                             -> MY or the prior year
--   ESRD                                         -> any time through MY end
-- Age conditions for frailty are applied later, in the member fact.
-- =============================================================================
CREATE OR REPLACE TABLE int.exclusion_event AS
WITH p AS (SELECT * FROM ref.cbp_params),
windows AS (
    SELECT * FROM (VALUES
        ('HOSPICE',          'MY'),
        ('PALLIATIVE_CARE',  'MY'),
        ('PREGNANCY',        'MY'),
        ('FRAILTY',          'MY'),
        ('ADVANCED_ILLNESS', 'MY_AND_PRIOR'),
        ('ESRD',             'EVER')
    ) t(value_set, lookback)
)
SELECT cc.member_id,
       vs.value_set                    AS exclusion_category,
       min(cc.dos)                     AS first_event_date,
       count(DISTINCT cc.claim_id)     AS supporting_claims
FROM stg.claim_code cc
JOIN ref.value_set vs ON vs.code_system = cc.code_system AND vs.code = cc.code
JOIN windows w        ON w.value_set = vs.value_set
CROSS JOIN p
WHERE cc.dos <= p.my_end
  AND cc.dos >= CASE w.lookback
                    WHEN 'MY'           THEN p.my_start
                    WHEN 'MY_AND_PRIOR' THEN p.prior_year_start
                    ELSE DATE '1900-01-01'
                END
GROUP BY cc.member_id, vs.value_set;
