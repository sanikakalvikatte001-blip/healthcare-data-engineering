-- SCD2 dimension integrity and source-to-mart reconciliation.
INSERT INTO test_result
SELECT 'dim_member: member_sk is unique', count(*) - count(DISTINCT member_sk)
FROM mart.dim_member;

INSERT INTO test_result
SELECT 'dim_member: exactly one current version per member', count(*)
FROM (SELECT member_id FROM mart.dim_member GROUP BY member_id
      HAVING count(*) FILTER (WHERE is_current) <> 1);

INSERT INTO test_result
SELECT 'dim_member: versions are contiguous (no gaps / overlaps)', count(*)
FROM (SELECT valid_from, lag(valid_to) OVER (PARTITION BY member_id ORDER BY valid_from) AS prev_to
      FROM mart.dim_member)
WHERE prev_to IS NOT NULL AND valid_from <> prev_to + 1;

INSERT INTO test_result
SELECT 'dim_member: no back-to-back versions with identical attributes', count(*)
FROM (SELECT product_line, pcp_npi,
             lag(product_line) OVER w AS prev_pl, lag(pcp_npi) OVER w AS prev_pcp
      FROM mart.dim_member WINDOW w AS (PARTITION BY member_id ORDER BY valid_from))
WHERE product_line = prev_pl AND pcp_npi = prev_pcp;

INSERT INTO test_result
SELECT 'dim_member: S18 has Medicaid then Medicare versions split on 2026-07-01', count(*)
FROM (SELECT string_agg(product_line || '@' || valid_from, ',' ORDER BY valid_from) AS h
      FROM mart.dim_member WHERE member_id = 'S18')
WHERE h <> 'MEDICAID@2024-01-01,MEDICARE@2026-07-01';

INSERT INTO test_result
SELECT 'fct_bp_reading: every reading resolves to the dim version valid on its date', count(*)
FROM mart.fct_bp_reading f
LEFT JOIN mart.dim_member d ON d.member_sk = f.member_sk
WHERE d.member_sk IS NULL
   OR (f.member_version_match = 'POINT_IN_TIME'
       AND f.reading_date NOT BETWEEN d.valid_from AND d.valid_to)
   OR (f.member_version_match = 'BEFORE_FIRST_VERSION'
       AND (d.version_no <> 1 OR f.reading_date >= d.valid_from));

INSERT INTO test_result
SELECT 'stg_member_coverage: resent segments collapsed to one row per (member, eff_date)', count(*)
FROM (SELECT member_id, eff_date FROM stg.member_coverage GROUP BY ALL HAVING count(*) > 1);

INSERT INTO test_result
SELECT 'reconciliation: raw EHR vitals = loaded readings + DQ rejects', abs(r.n - (f.n + x.n))
FROM (SELECT count(*) n FROM raw.ehr_vitals) r,
     (SELECT count(*) n FROM mart.fct_bp_reading WHERE source_system = 'EHR') f,
     (SELECT count(*) n FROM mart.dq_bp_reject) x;

INSERT INTO test_result
SELECT 'reconciliation: every claim with CPT II BP codes appears once in fct_bp_reading', abs(c.n - f.n)
FROM (SELECT count(DISTINCT claim_id) n FROM raw.claim_lines
      WHERE upper(trim(proc_code)) IN (SELECT code FROM ref.cpt2_bp_code)) c,
     (SELECT count(*) n FROM mart.fct_bp_reading WHERE source_system = 'CLAIM_CPT2') f;
