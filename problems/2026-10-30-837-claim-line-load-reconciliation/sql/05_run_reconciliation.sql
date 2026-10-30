-- =============================================================================
-- 05_run_reconciliation.sql
-- recon.run_reconciliation(batch_id) -> run_id
--
--   1. open a run in recon.run_log
--   2. control totals, source vs target, at batch and service-month grain
--   3. execute every active rule in the catalog (dynamic SQL), write
--      row-level exceptions and one result row per rule
--   4. roll up to a run status: FAIL if any CRITICAL rule is over tolerance,
--      WARN if any WARN rule is over tolerance, otherwise PASS
-- =============================================================================

CREATE OR REPLACE FUNCTION recon.run_reconciliation(p_batch_id text)
RETURNS bigint
LANGUAGE plpgsql AS
$$
DECLARE
    v_run_id  bigint;
    v_rule    recon.rule_catalog%ROWTYPE;
    v_sql     text;
    v_count   integer;
    v_status  text;
BEGIN
    INSERT INTO recon.run_log (load_batch_id) VALUES (p_batch_id)
    RETURNING run_id INTO v_run_id;

    -- ---------------------------------------------------------------------
    -- 2. Control totals. Built from one UNION ALL of both sides so a month
    --    present on only one side still shows up (with 0 on the other).
    -- ---------------------------------------------------------------------
    WITH both_sides AS (
        SELECT 'S' AS side, claim_id, service_from_date, units, billed_amount
        FROM recon.v_expected_line WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT 'T', claim_id, service_from_date, units, billed_amount
        FROM dw.fact_claim_line WHERE load_batch_id = p_batch_id
    ),
    by_grain AS (
        SELECT 'BATCH' AS grain, p_batch_id AS grain_value, side,
               count(*) AS line_count, count(DISTINCT claim_id) AS claim_count,
               sum(billed_amount) AS billed_amount, sum(units) AS units
        FROM both_sides GROUP BY side
        UNION ALL
        SELECT 'SERVICE_MONTH', to_char(service_from_date, 'YYYY-MM'), side,
               count(*), count(DISTINCT claim_id), sum(billed_amount), sum(units)
        FROM both_sides GROUP BY to_char(service_from_date, 'YYYY-MM'), side
    ),
    unpivoted AS (
        SELECT g.grain, g.grain_value, g.side, m.metric, m.val
        FROM by_grain g
        CROSS JOIN LATERAL (VALUES ('line_count',    g.line_count::numeric),
                                   ('claim_count',   g.claim_count::numeric),
                                   ('billed_amount', g.billed_amount),
                                   ('units',         g.units)) AS m(metric, val)
    )
    INSERT INTO recon.control_total (run_id, grain, grain_value, metric, source_value, target_value)
    SELECT v_run_id, grain, grain_value, metric,
           coalesce(sum(val) FILTER (WHERE side = 'S'), 0),
           coalesce(sum(val) FILTER (WHERE side = 'T'), 0)
    FROM unpivoted
    GROUP BY grain, grain_value, metric;

    -- ---------------------------------------------------------------------
    -- 3. Rules. Each rule runs in its own sub-block so one broken rule is
    --    recorded as FAIL instead of aborting the whole run.
    -- ---------------------------------------------------------------------
    FOR v_rule IN
        SELECT * FROM recon.rule_catalog WHERE is_active ORDER BY rule_group, rule_code
    LOOP
        v_sql := replace(v_rule.check_sql, '{batch_id}', quote_literal(p_batch_id));
        BEGIN
            EXECUTE format(
                'INSERT INTO recon.exception (run_id, rule_code, severity, claim_id, line_no, detail)
                 SELECT %s, %L, %L, q.* FROM (%s) AS q(claim_id, line_no, detail)',
                v_run_id, v_rule.rule_code, v_rule.severity, v_sql);
            GET DIAGNOSTICS v_count = ROW_COUNT;

            v_status := CASE WHEN v_count <= v_rule.max_exceptions THEN 'PASS'
                             WHEN v_rule.severity = 'CRITICAL'     THEN 'FAIL'
                             ELSE 'WARN' END;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'rule % failed to execute: %', v_rule.rule_code, SQLERRM;
            v_count  := -1;
            v_status := 'FAIL';
        END;

        INSERT INTO recon.rule_result (run_id, rule_code, severity, exception_count, max_exceptions, rule_status)
        VALUES (v_run_id, v_rule.rule_code, v_rule.severity, v_count, v_rule.max_exceptions, v_status);
    END LOOP;

    -- ---------------------------------------------------------------------
    -- 4. Run status.
    -- ---------------------------------------------------------------------
    SELECT CASE WHEN bool_or(rule_status = 'FAIL') THEN 'FAIL'
                WHEN bool_or(rule_status = 'WARN') THEN 'WARN'
                ELSE 'PASS' END
    INTO v_status
    FROM recon.rule_result WHERE run_id = v_run_id;

    UPDATE recon.run_log
    SET finished_at = clock_timestamp(), run_status = v_status
    WHERE run_id = v_run_id;

    RAISE NOTICE 'reconciliation run % for batch %: %', v_run_id, p_batch_id, v_status;
    RETURN v_run_id;
END;
$$;
