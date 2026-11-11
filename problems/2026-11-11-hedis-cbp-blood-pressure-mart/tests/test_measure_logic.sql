-- Measure funnel and rate integrity.
INSERT INTO test_result
SELECT 'measure: one fct_cbp_member row per member covered in the MY', count(*)
FROM (
    SELECT member_id FROM mart.fct_cbp_member GROUP BY member_id HAVING count(*) > 1
    UNION ALL
    (SELECT DISTINCT c.member_id FROM stg.member_coverage c, ref.cbp_params p
     WHERE c.eff_date <= p.my_end AND c.term_date >= p.my_start
     EXCEPT SELECT member_id FROM mart.fct_cbp_member)
);

INSERT INTO test_result
SELECT 'measure: numerator within denominator within eligible population', count(*)
FROM mart.fct_cbp_member
WHERE (in_numerator AND NOT in_denominator)
   OR (in_denominator AND NOT in_eligible_population)
   OR (in_denominator AND exclusion_reason IS NOT NULL);

INSERT INTO test_result
SELECT 'measure: numerator members are strictly below 140/90', count(*)
FROM mart.fct_cbp_member
WHERE in_numerator AND NOT (rep_systolic < 140 AND rep_diastolic < 90);

INSERT INTO test_result
SELECT 'measure: denominator members are 18-85, CE, and have 2+ HTN visit dates', count(*)
FROM mart.fct_cbp_member
WHERE in_denominator
  AND NOT (age_at_my_end BETWEEN 18 AND 85 AND is_continuously_enrolled AND htn_visit_dates >= 2);

INSERT INTO test_result
SELECT 'measure: ALL row equals the sum of product lines and rate = num/den', count(*)
FROM (
    SELECT a.product_line
    FROM mart.cbp_rate a,
         (SELECT sum(denominator) d, sum(numerator) n, sum(eligible_population) e
          FROM mart.cbp_rate WHERE product_line <> 'ALL') s
    WHERE a.product_line = 'ALL'
      AND (a.denominator <> s.d OR a.numerator <> s.n OR a.eligible_population <> s.e)
    UNION ALL
    SELECT product_line FROM mart.cbp_rate
    WHERE rate_pct <> round(100.0 * numerator / denominator, 2)
);

INSERT INTO test_result
SELECT 'measure: care-gap list = denominator minus numerator', count(*)
FROM (
    (SELECT member_id FROM mart.fct_cbp_member WHERE in_denominator AND NOT in_numerator
     EXCEPT SELECT member_id FROM mart.cbp_care_gap)
    UNION ALL
    (SELECT member_id FROM mart.cbp_care_gap
     EXCEPT SELECT member_id FROM mart.fct_cbp_member WHERE in_denominator AND NOT in_numerator)
);
