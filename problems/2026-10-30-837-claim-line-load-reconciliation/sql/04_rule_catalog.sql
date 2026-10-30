-- =============================================================================
-- 04_rule_catalog.sql
-- Config-driven rules. Adding a check = inserting a row; no code change.
-- Each check_sql returns (claim_id text, line_no int, detail jsonb).
-- {batch_id} is replaced with the quoted batch id at run time.
-- =============================================================================

TRUNCATE recon.rule_catalog CASCADE;

INSERT INTO recon.rule_catalog (rule_code, rule_group, severity, max_exceptions, description, check_sql)
VALUES

-- ---------------------------------------------------------------------------
-- RECON: does the warehouse match what staging says it should contain?
-- ---------------------------------------------------------------------------
('RECON_MISSING_IN_TARGET', 'RECON', 'CRITICAL', 0,
 'Source line has no matching warehouse line on (claim_id, line_no).',
 $q$
 SELECT e.claim_id, e.line_no,
        jsonb_build_object('billed_amount', e.billed_amount, 'service_from_date', e.service_from_date)
 FROM recon.v_expected_line e
 WHERE e.load_batch_id = {batch_id}
   AND NOT EXISTS (SELECT 1 FROM dw.fact_claim_line f
                   WHERE f.load_batch_id = e.load_batch_id
                     AND f.claim_id = e.claim_id AND f.line_no = e.line_no)
 $q$),

('RECON_EXTRA_IN_TARGET', 'RECON', 'CRITICAL', 0,
 'Warehouse line has no matching source line in the same batch.',
 $q$
 SELECT f.claim_id, f.line_no,
        jsonb_build_object('claim_line_sk', f.claim_line_sk, 'billed_amount', f.billed_amount)
 FROM dw.fact_claim_line f
 WHERE f.load_batch_id = {batch_id}
   AND NOT EXISTS (SELECT 1 FROM recon.v_expected_line e
                   WHERE e.load_batch_id = f.load_batch_id
                     AND e.claim_id = f.claim_id AND e.line_no = f.line_no)
 $q$),

('RECON_DUPLICATE_IN_TARGET', 'RECON', 'CRITICAL', 0,
 'Business key loaded more than once. One exception per surplus copy.',
 $q$
 SELECT claim_id, line_no,
        jsonb_build_object('claim_line_sk', claim_line_sk, 'copy_number', copy_no)
 FROM (SELECT f.claim_id, f.line_no, f.claim_line_sk,
              row_number() OVER (PARTITION BY f.claim_id, f.line_no ORDER BY f.claim_line_sk) AS copy_no
       FROM dw.fact_claim_line f
       WHERE f.load_batch_id = {batch_id}) d
 WHERE copy_no > 1
 $q$),

('RECON_VALUE_MISMATCH', 'RECON', 'CRITICAL', 0,
 'Key matches but the normalized row hash differs. Detail lists the columns that differ.',
 $q$
 WITH t AS (   -- first copy only, so duplicates are not double-reported here
     SELECT DISTINCT ON (claim_id, line_no) *
     FROM recon.v_actual_line_hashed
     WHERE load_batch_id = {batch_id}
     ORDER BY claim_id, line_no, claim_line_sk
 )
 SELECT e.claim_id, e.line_no,
        jsonb_build_object(
          'columns', to_jsonb(array_remove(ARRAY[
              CASE WHEN e.member_id         IS DISTINCT FROM t.member_id         THEN 'member_id' END,
              CASE WHEN e.billing_npi       IS DISTINCT FROM t.billing_npi       THEN 'billing_npi' END,
              CASE WHEN e.rendering_npi     IS DISTINCT FROM t.rendering_npi     THEN 'rendering_npi' END,
              CASE WHEN e.service_from_date IS DISTINCT FROM t.service_from_date THEN 'service_from_date' END,
              CASE WHEN e.place_of_service  IS DISTINCT FROM t.place_of_service  THEN 'place_of_service' END,
              CASE WHEN e.cpt_code          IS DISTINCT FROM t.cpt_code          THEN 'cpt_code' END,
              CASE WHEN e.modifier_1        IS DISTINCT FROM t.modifier_1        THEN 'modifier_1' END,
              CASE WHEN e.dx_code_1         IS DISTINCT FROM t.dx_code_1         THEN 'dx_code_1' END,
              CASE WHEN e.units             IS DISTINCT FROM t.units             THEN 'units' END,
              CASE WHEN e.billed_amount     IS DISTINCT FROM t.billed_amount     THEN 'billed_amount' END
          ], NULL)),
          'source_hash', e.row_hash, 'target_hash', t.row_hash,
          'source_billed', e.billed_amount, 'target_billed', t.billed_amount)
 FROM recon.v_expected_line_hashed e
 JOIN t ON t.claim_id = e.claim_id AND t.line_no = e.line_no
 WHERE e.load_batch_id = {batch_id}
   AND e.row_hash <> t.row_hash
 $q$),

-- ---------------------------------------------------------------------------
-- SOURCE_DQ: is the inbound 837 content itself valid? These are WARN: the
-- lines load, but are routed to a steward / back to the submitter.
-- ---------------------------------------------------------------------------
('DQ_NPI_LUHN', 'SOURCE_DQ', 'WARN', 0,
 'Billing or rendering NPI fails the 10-digit format or Luhn check digit.',
 $q$
 SELECT claim_id, line_no,
        jsonb_build_object('billing_npi', billing_npi, 'rendering_npi', rendering_npi)
 FROM recon.v_expected_line
 WHERE load_batch_id = {batch_id}
   AND (NOT util.npi_is_valid(billing_npi) OR NOT util.npi_is_valid(rendering_npi))
 $q$),

('DQ_ICD10_FORMAT', 'SOURCE_DQ', 'WARN', 0,
 'Diagnosis is not ICD-10-CM shape for X12 (letter, digit, 1-5 alphanumerics, no decimal point).',
 $q$
 SELECT claim_id, line_no, jsonb_build_object('dx_code_1', dx_code_1)
 FROM recon.v_expected_line
 WHERE load_batch_id = {batch_id}
   AND (dx_code_1 IS NULL OR dx_code_1 !~ '^[A-Z][0-9][0-9A-Z]{1,5}$')
 $q$),

('DQ_FUTURE_DOS', 'SOURCE_DQ', 'WARN', 0,
 'Service date is after the date the file was received.',
 $q$
 SELECT btrim(s.claim_id), btrim(s.line_no)::int,
        jsonb_build_object('service_from_date', s.service_from_date, 'received_date', s.received_date)
 FROM src.stg_837p_claim_line s
 WHERE s.load_batch_id = {batch_id}
   AND to_date(s.service_from_date, 'YYYYMMDD') > to_date(s.received_date, 'YYYYMMDD')
 $q$),

('DQ_BILLED_NONPOSITIVE', 'SOURCE_DQ', 'WARN', 5,
 'Billed amount is zero or negative. Small volumes are tolerated (no-charge lines).',
 $q$
 SELECT claim_id, line_no, jsonb_build_object('billed_amount', billed_amount)
 FROM recon.v_expected_line
 WHERE load_batch_id = {batch_id} AND billed_amount <= 0
 $q$),

('DQ_UNITS_ZERO', 'SOURCE_DQ', 'WARN', 0,
 'Service units are zero or missing.',
 $q$
 SELECT claim_id, line_no, jsonb_build_object('units', units)
 FROM recon.v_expected_line
 WHERE load_batch_id = {batch_id} AND coalesce(units, 0) <= 0
 $q$),

('DQ_POS_INVALID', 'SOURCE_DQ', 'WARN', 0,
 'Place of service not in the CMS POS reference subset used by this payer.',
 $q$
 SELECT claim_id, line_no, jsonb_build_object('place_of_service', place_of_service)
 FROM recon.v_expected_line
 WHERE load_batch_id = {batch_id}
   AND coalesce(place_of_service, '') NOT IN
       ('02','10','11','12','19','20','21','22','23','24','31','32','49','50','65','71','72','81')
 $q$),

('DQ_MEMBER_ID_MISSING', 'SOURCE_DQ', 'WARN', 0,
 'Subscriber/member id is blank, so the line cannot be tied to eligibility.',
 $q$
 SELECT claim_id, line_no, jsonb_build_object('member_id', member_id)
 FROM recon.v_expected_line
 WHERE load_batch_id = {batch_id} AND member_id IS NULL
 $q$);
