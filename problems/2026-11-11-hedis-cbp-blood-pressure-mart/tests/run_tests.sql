-- =============================================================================
-- run_tests.sql - data tests for the CBP warehouse (run after pipeline.sql).
--   duckdb -bail cbp.duckdb < tests/run_tests.sql
-- Each test inserts (test_name, failures). A test passes when failures = 0.
-- The script ends with error() - non-zero exit code - if any test fails.
-- =============================================================================
.bail on
CREATE OR REPLACE TEMP TABLE test_result (test_name VARCHAR, failures BIGINT);

.read tests/test_scenarios.sql
.read tests/test_measure_logic.sql
.read tests/test_bp_rules.sql
.read tests/test_dim_and_reconciliation.sql

.mode box
SELECT CASE WHEN failures = 0 THEN 'PASS' ELSE 'FAIL' END AS status, test_name, failures
FROM test_result ORDER BY status, test_name;

.mode list
SELECT count(*) FILTER (WHERE failures = 0) || ' passed, '
    || count(*) FILTER (WHERE failures <> 0) || ' failed' AS summary
FROM test_result;

.headers off
SELECT error(count(*) || ' data test(s) failed')
FROM test_result WHERE failures <> 0
HAVING count(*) > 0;
