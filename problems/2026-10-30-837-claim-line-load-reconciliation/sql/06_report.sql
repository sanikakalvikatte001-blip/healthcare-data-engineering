-- =============================================================================
-- 06_report.sql
-- Reconciliation report for the latest run. Run with psql.
-- =============================================================================

\echo '== Run =='
SELECT run_id, load_batch_id, run_status,
       round(extract(epoch FROM finished_at - started_at) * 1000) AS duration_ms
FROM recon.run_log ORDER BY run_id DESC LIMIT 1;

\echo '== Control totals (batch grain) =='
SELECT metric, source_value, target_value, variance
FROM recon.control_total
WHERE run_id = (SELECT max(run_id) FROM recon.run_log) AND grain = 'BATCH'
ORDER BY metric;

\echo '== Control totals by service month (only months with a variance) =='
SELECT grain_value AS service_month, metric, source_value, target_value, variance
FROM recon.control_total
WHERE run_id = (SELECT max(run_id) FROM recon.run_log)
  AND grain = 'SERVICE_MONTH' AND variance <> 0
ORDER BY service_month, metric;

\echo '== Rule results =='
SELECT rule_code, severity, exception_count, max_exceptions, rule_status
FROM recon.rule_result
WHERE run_id = (SELECT max(run_id) FROM recon.run_log)
ORDER BY CASE severity WHEN 'CRITICAL' THEN 0 ELSE 1 END, rule_code;

\echo '== Value mismatches by column =='
SELECT col AS column_name, count(*) AS lines
FROM recon.exception x
CROSS JOIN LATERAL jsonb_array_elements_text(x.detail -> 'columns') AS col
WHERE x.run_id = (SELECT max(run_id) FROM recon.run_log)
  AND x.rule_code = 'RECON_VALUE_MISMATCH'
GROUP BY col ORDER BY lines DESC, col;

\echo '== Sample exceptions (first 2 per rule) =='
SELECT rule_code, claim_id, line_no, detail
FROM (SELECT x.*, row_number() OVER (PARTITION BY rule_code ORDER BY claim_id, line_no) AS rn
      FROM recon.exception x
      WHERE run_id = (SELECT max(run_id) FROM recon.run_log)) s
WHERE rn <= 2
ORDER BY rule_code, claim_id, line_no;

\echo '== Why normalize first: naive raw-text comparison vs normalized hash =='
-- Compare staging text to warehouse text with no normalization. Every padded
-- CPT, lowercase modifier and "125.5" vs "125.50" amount becomes a false alarm.
WITH t AS (
    SELECT DISTINCT ON (claim_id, line_no) * FROM dw.fact_claim_line
    WHERE load_batch_id = 'B20261030' ORDER BY claim_id, line_no, claim_line_sk
)
SELECT count(*) FILTER (WHERE md5(concat_ws('|', s.cpt_code, s.modifier_1, s.billed_amount, s.units, s.service_from_date))
                           <> md5(concat_ws('|', t.cpt_code, t.modifier_1, t.billed_amount::text, t.units::text,
                                                 to_char(t.service_from_date, 'YYYYMMDD')))) AS naive_mismatches,
       (SELECT exception_count FROM recon.rule_result
        WHERE run_id = (SELECT max(run_id) FROM recon.run_log)
          AND rule_code = 'RECON_VALUE_MISMATCH')                                        AS normalized_mismatches
FROM src.stg_837p_claim_line s
JOIN t ON t.claim_id = s.claim_id AND t.line_no = s.line_no::int;
