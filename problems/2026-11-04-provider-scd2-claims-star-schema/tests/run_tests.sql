-- =============================================================================
-- tests/run_tests.sql — dbt-style data tests in plain DuckDB SQL.
-- Each assert_* view returns the rows that VIOLATE a rule; 0 rows = pass.
-- The run fails (non-zero exit) via error() if any test has failures.
--   duckdb -bail warehouse.duckdb < tests/run_tests.sql
-- =============================================================================
.bail on
CREATE SCHEMA IF NOT EXISTS tests;
.read tests/assert_dim_one_current_row_per_npi.sql
.read tests/assert_dim_versions_contiguous.sql
.read tests/assert_dim_no_redundant_versions.sql
.read tests/assert_dim_surrogate_key_unique.sql
.read tests/assert_fct_grain_and_no_fanout.sql
.read tests/assert_fct_point_in_time_key.sql
.read tests/assert_reconciliation_raw_to_fact.sql
.read tests/assert_scenarios_planted_in_seed.sql

CREATE OR REPLACE TABLE tests.test_results AS
SELECT 'assert_dim_one_current_row_per_npi' AS test_name, count(*) AS failures FROM tests.assert_dim_one_current_row_per_npi
UNION ALL SELECT 'assert_dim_versions_contiguous',    count(*) FROM tests.assert_dim_versions_contiguous
UNION ALL SELECT 'assert_dim_no_redundant_versions',  count(*) FROM tests.assert_dim_no_redundant_versions
UNION ALL SELECT 'assert_dim_surrogate_key_unique',   count(*) FROM tests.assert_dim_surrogate_key_unique
UNION ALL SELECT 'assert_fct_grain_and_no_fanout',    count(*) FROM tests.assert_fct_grain_and_no_fanout
UNION ALL SELECT 'assert_fct_point_in_time_key',      count(*) FROM tests.assert_fct_point_in_time_key
UNION ALL SELECT 'assert_reconciliation_raw_to_fact', count(*) FROM tests.assert_reconciliation_raw_to_fact
UNION ALL SELECT 'assert_scenarios_planted_in_seed',  count(*) FROM tests.assert_scenarios_planted_in_seed;

SELECT test_name, failures, CASE WHEN failures = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM tests.test_results ORDER BY test_name;

-- failing scenario names (empty when green)
SELECT scenario AS failed_scenario FROM tests.assert_scenarios_planted_in_seed;

SELECT CASE WHEN sum(failures) > 0
            THEN error(sum(failures)::VARCHAR || ' data test failure(s)')
            ELSE 'ALL ' || count(*)::VARCHAR || ' TESTS PASSED' END AS summary
FROM tests.test_results;
