-- =============================================================================
-- tests/test_reconciliation.sql
-- Plain-SQL test suite: each test is a DO block using ASSERT. psql runs with
-- ON_ERROR_STOP=1, so the first failed assertion stops the suite non-zero.
-- Expects a fresh build (tests/run_tests.sh does that).
-- =============================================================================

\set QUIET on
SET client_min_messages = notice;

-- ---------------------------------------------------------------------------
-- T01  NPI Luhn check against the CMS worked example and edge cases
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    ASSERT util.npi_check_digit('123456789') = 3, 'CMS example base 123456789 -> check digit 3';
    ASSERT util.npi_is_valid('1234567893'),        'CMS example NPI should be valid';
    ASSERT NOT util.npi_is_valid('1234567890'),    'wrong check digit should fail';
    ASSERT NOT util.npi_is_valid('123456789'),     '9 digits should fail';
    ASSERT NOT util.npi_is_valid('3234567893'),    'NPIs start with 1 or 2';
    ASSERT NOT util.npi_is_valid('12345678A3'),    'non-numeric should fail';
    ASSERT NOT util.npi_is_valid(NULL),            'NULL should be invalid, not NULL';
    RAISE NOTICE 'PASS T01 npi luhn';
END $$;

-- ---------------------------------------------------------------------------
-- T02  Formatting differences must hash the same; real differences must not
-- ---------------------------------------------------------------------------
DO $$
DECLARE h1 text; h2 text; h3 text;
BEGIN
    h1 := util.claim_line_hash('M000001', '1234567893', '1234567893', date '2026-08-01',
                               '11', util.clean_code(' 99213 '), util.clean_code('gt'), 'I10',
                               '1'::numeric, '125.5'::numeric);
    h2 := util.claim_line_hash('M000001', '1234567893', '1234567893', date '2026-08-01',
                               '11', '99213', 'GT', 'I10', 1.00, 125.50);
    h3 := util.claim_line_hash('M000001', '1234567893', '1234567893', date '2026-08-01',
                               '11', '99213', 'GT', 'I10', 1.00, 125.51);
    ASSERT h1 = h2,  'padding / case / numeric scale must not change the hash';
    ASSERT h2 <> h3, 'a one-cent change must change the hash';
    ASSERT util.claim_line_hash(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        <> util.claim_line_hash('', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
        'NULL and empty string must hash differently';
    RAISE NOTICE 'PASS T02 normalized row hash';
END $$;

-- ---------------------------------------------------------------------------
-- T03  Defective load: every injected defect is found, with exact counts
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_run bigint := recon.run_reconciliation('B20261030');
    v_got jsonb;
    v_expected jsonb := '{
        "RECON_MISSING_IN_TARGET": 7, "RECON_DUPLICATE_IN_TARGET": 4,
        "RECON_EXTRA_IN_TARGET": 3,   "RECON_VALUE_MISMATCH": 13,
        "DQ_NPI_LUHN": 6, "DQ_ICD10_FORMAT": 5, "DQ_FUTURE_DOS": 2,
        "DQ_BILLED_NONPOSITIVE": 3, "DQ_UNITS_ZERO": 2, "DQ_POS_INVALID": 2,
        "DQ_MEMBER_ID_MISSING": 1}';
BEGIN
    SELECT jsonb_object_agg(rule_code, exception_count) INTO v_got
    FROM recon.rule_result WHERE run_id = v_run;
    ASSERT v_got = v_expected, format('rule counts: got %s', v_got);

    ASSERT (SELECT run_status FROM recon.run_log WHERE run_id = v_run) = 'FAIL',
        'critical recon exceptions must fail the run';

    -- The exact keys, not just the counts.
    ASSERT (SELECT array_agg(claim_id ORDER BY claim_id) FROM recon.exception
            WHERE run_id = v_run AND rule_code = 'RECON_MISSING_IN_TARGET')
         = ARRAY['CLM0000301','CLM0000302','CLM0000303','CLM0000304',
                 'CLM0000305','CLM0000306','CLM0000307'],
        'missing keys';
    ASSERT (SELECT array_agg(DISTINCT claim_id ORDER BY claim_id) FROM recon.exception
            WHERE run_id = v_run AND rule_code = 'RECON_EXTRA_IN_TARGET')
         = ARRAY['CLM9000001','CLM9000002'],
        'extra keys';
    RAISE NOTICE 'PASS T03 defect detection counts and keys';
END $$;

-- ---------------------------------------------------------------------------
-- T04  Mismatch detail names the right columns, including a 2-column line
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_run bigint := (SELECT max(run_id) FROM recon.run_log);
BEGIN
    ASSERT (SELECT detail -> 'columns' FROM recon.exception
            WHERE run_id = v_run AND rule_code = 'RECON_VALUE_MISMATCH' AND claim_id = 'CLM0000351')
         = '["service_from_date", "billed_amount"]'::jsonb, 'CLM0000351 has two bad columns';
    ASSERT (SELECT count(*) FROM recon.exception
            WHERE run_id = v_run AND rule_code = 'RECON_VALUE_MISMATCH'
              AND detail -> 'columns' = '["modifier_1"]') = 4, 'four dropped modifiers';
    -- Cosmetic noise (padded CPT, lowercase modifier) on every 10th claim must not be flagged.
    ASSERT NOT EXISTS (SELECT 1 FROM recon.exception
                       WHERE run_id = v_run AND rule_code = 'RECON_VALUE_MISMATCH'
                         AND right(claim_id, 1) = '0'), 'no false positives from formatting';
    RAISE NOTICE 'PASS T04 mismatch column detail';
END $$;

-- ---------------------------------------------------------------------------
-- T05  Why counts are not enough: line count ties out while the load is wrong
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_run bigint := (SELECT max(run_id) FROM recon.run_log);
BEGIN
    ASSERT (SELECT variance FROM recon.control_total
            WHERE run_id = v_run AND grain = 'BATCH' AND metric = 'line_count') = 0,
        '-7 missing +4 duplicate +3 extra nets to zero';
    ASSERT (SELECT variance FROM recon.control_total
            WHERE run_id = v_run AND grain = 'BATCH' AND metric = 'claim_count') = 1,
        'claim count: +2 extra claims, -1 single-line claim lost (CLM0000304)';
    ASSERT (SELECT variance FROM recon.control_total
            WHERE run_id = v_run AND grain = 'BATCH' AND metric = 'billed_amount') <> 0,
        'billed amount must not tie out';
    -- Batch variance equals the sum of the month variances (nothing falls through).
    ASSERT (SELECT sum(variance) FILTER (WHERE grain = 'SERVICE_MONTH')
                 = sum(variance) FILTER (WHERE grain = 'BATCH')
            FROM recon.control_total WHERE run_id = v_run AND metric = 'billed_amount'),
        'month variances roll up to batch variance';
    RAISE NOTICE 'PASS T05 control totals';
END $$;

-- ---------------------------------------------------------------------------
-- T06  Tolerance: a WARN rule under its max_exceptions passes
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_run bigint := (SELECT max(run_id) FROM recon.run_log);
BEGIN
    ASSERT (SELECT rule_status FROM recon.rule_result
            WHERE run_id = v_run AND rule_code = 'DQ_BILLED_NONPOSITIVE') = 'PASS', '3 <= 5 tolerated';
    ASSERT (SELECT rule_status FROM recon.rule_result
            WHERE run_id = v_run AND rule_code = 'DQ_NPI_LUHN') = 'WARN', '6 > 0 warns';
    RAISE NOTICE 'PASS T06 rule tolerance';
END $$;

-- ---------------------------------------------------------------------------
-- T07  A broken rule is isolated: recorded as FAIL (-1), other rules still run
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_run bigint;
BEGIN
    INSERT INTO recon.rule_catalog (rule_code, rule_group, severity, description, check_sql)
    VALUES ('TEST_BROKEN_RULE', 'SOURCE_DQ', 'WARN', 'deliberately invalid SQL',
            'SELECT claim_id, line_no, NULL::jsonb FROM no_such_table');
    v_run := recon.run_reconciliation('B20261030');

    ASSERT (SELECT exception_count = -1 AND rule_status = 'FAIL' FROM recon.rule_result
            WHERE run_id = v_run AND rule_code = 'TEST_BROKEN_RULE'), 'broken rule recorded as FAIL';
    ASSERT (SELECT count(*) FROM recon.rule_result WHERE run_id = v_run) = 12, 'all rules evaluated';

    DELETE FROM recon.rule_result WHERE rule_code = 'TEST_BROKEN_RULE';
    DELETE FROM recon.rule_catalog WHERE rule_code = 'TEST_BROKEN_RULE';
    RAISE NOTICE 'PASS T07 broken rule isolation';
END $$;

-- ---------------------------------------------------------------------------
-- T08  Clean reload: load is idempotent and reconciles with zero RECON
--      exceptions; source DQ warnings remain (they live in the source data)
-- ---------------------------------------------------------------------------
CALL dw.load_fact_claim_line('B20261030');
CALL dw.load_fact_claim_line('B20261030');   -- second call must not duplicate

DO $$
DECLARE v_run bigint := recon.run_reconciliation('B20261030');
BEGIN
    ASSERT (SELECT count(*) FROM dw.fact_claim_line WHERE load_batch_id = 'B20261030') = 5000,
        'idempotent load keeps 5,000 lines';
    ASSERT (SELECT sum(exception_count) FROM recon.rule_result
            WHERE run_id = v_run AND rule_code LIKE 'RECON%') = 0, 'clean load has no recon exceptions';
    ASSERT NOT EXISTS (SELECT 1 FROM recon.control_total WHERE run_id = v_run AND variance <> 0),
        'all control totals tie out';
    ASSERT (SELECT sum(exception_count) FROM recon.rule_result
            WHERE run_id = v_run AND rule_code LIKE 'DQ%') = 21, 'source DQ findings unchanged';
    ASSERT (SELECT run_status FROM recon.run_log WHERE run_id = v_run) = 'WARN',
        'clean load with source warnings => WARN';
    RAISE NOTICE 'PASS T08 clean reload reconciles';
END $$;

-- ---------------------------------------------------------------------------
-- T09  Re-runs are independent: every run keeps its own exceptions
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    ASSERT (SELECT count(DISTINCT run_id) FROM recon.exception) = 3, 'three runs with exceptions';
    ASSERT NOT EXISTS (
        SELECT 1 FROM recon.rule_result r
        WHERE r.exception_count >= 0
          AND r.exception_count <> (SELECT count(*) FROM recon.exception x
                                    WHERE x.run_id = r.run_id AND x.rule_code = r.rule_code)),
        'rule_result counts match stored exception rows for every run';
    RAISE NOTICE 'PASS T09 run history consistent';
END $$;

\echo 'ALL TESTS PASSED'
