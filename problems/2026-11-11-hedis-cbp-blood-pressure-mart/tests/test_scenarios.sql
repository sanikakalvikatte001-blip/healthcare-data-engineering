-- Golden-scenario tests: every planted edge case (reference/expected_scenarios.csv)
-- must land on its expected outcome and Dec-31 product line.
INSERT INTO test_result
SELECT 'scenarios: each expected scenario member exists in fct_cbp_member', count(*)
FROM read_csv('reference/expected_scenarios.csv', header = true) e
ANTI JOIN mart.fct_cbp_member f USING (member_id);

INSERT INTO test_result
SELECT 'scenarios: outcome matches expected_outcome', count(*)
FROM read_csv('reference/expected_scenarios.csv', header = true) e
JOIN mart.fct_cbp_member f USING (member_id)
WHERE f.outcome <> e.expected_outcome;

INSERT INTO test_result
SELECT 'scenarios: product line is the Dec 31 product line', count(*)
FROM read_csv('reference/expected_scenarios.csv', header = true) e
JOIN mart.fct_cbp_member f USING (member_id)
WHERE f.product_line <> e.expected_product_line;

-- Spot-check the representative BP values the CBP rules should produce
INSERT INTO test_result
SELECT 'scenarios: representative BP values (same-day lowest, CPT II bands)', count(*)
FROM (VALUES ('S02', 144, 86), ('S03', 136, 82), ('S05', 130, 80),
             ('S06', 139, 89), ('S07', 140, 79), ('S19', 138, 88), ('S21', 140, 89)) v(member_id, sbp, dbp)
LEFT JOIN mart.fct_cbp_member f USING (member_id)
WHERE f.rep_systolic IS DISTINCT FROM v.sbp OR f.rep_diastolic IS DISTINCT FROM v.dbp;
