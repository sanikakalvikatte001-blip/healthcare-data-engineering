-- Fact grain is (claim_id, line_no) and the point-in-time join neither drops
-- nor duplicates lines: row count equals the resolved intermediate table.
CREATE OR REPLACE VIEW tests.assert_fct_grain_and_no_fanout AS
SELECT 'duplicate grain' AS issue, claim_id, line_no
FROM marts.fct_claim_line
GROUP BY claim_id, line_no HAVING count(*) > 1
UNION ALL
SELECT 'row count mismatch', NULL, NULL
WHERE (SELECT count(*) FROM marts.fct_claim_line)
   <> (SELECT count(*) FROM intermediate.int_claim_lines_current);
