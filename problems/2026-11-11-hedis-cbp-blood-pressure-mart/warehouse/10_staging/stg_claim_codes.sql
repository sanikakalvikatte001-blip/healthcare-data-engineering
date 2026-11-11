-- =============================================================================
-- 10_staging / stg_claim_codes
-- Grain: one row per (claim line, code). Unpivots a claim line into every code
-- it carries - procedure (CPT / HCPCS), place of service and up to three
-- diagnoses - so value-set matching is a single equality join downstream.
-- Diagnosis codes are normalized: trimmed, upper-cased, dots removed.
-- =============================================================================
CREATE OR REPLACE TABLE stg.claim_line AS
SELECT
    trim(claim_id)                       AS claim_id,
    line_no::INT                         AS line_no,
    trim(member_id)                      AS member_id,
    dos::DATE                            AS dos,
    lpad(trim(pos_code), 2, '0')         AS pos_code,
    upper(trim(proc_code))               AS proc_code,
    upper(replace(trim(dx1), '.', ''))   AS dx1,
    upper(replace(trim(dx2), '.', ''))   AS dx2,
    upper(replace(trim(dx3), '.', ''))   AS dx3
FROM raw.claim_lines;

CREATE OR REPLACE TABLE stg.claim_code AS
WITH long AS (
    SELECT claim_id, line_no, member_id, dos, pos_code,
           CASE
               WHEN regexp_full_match(proc_code, '[0-9]{4}[0-9F]') THEN 'CPT'
               WHEN regexp_full_match(proc_code, '[A-Z][0-9]{4}')  THEN 'HCPCS'
               ELSE 'UNKNOWN'
           END            AS code_system,
           proc_code      AS code,
           'PROCEDURE'    AS code_role
    FROM stg.claim_line
    UNION ALL
    SELECT claim_id, line_no, member_id, dos, pos_code, 'POS', pos_code, 'POS'
    FROM stg.claim_line
    UNION ALL
    SELECT claim_id, line_no, member_id, dos, pos_code, 'ICD10CM', dx, 'DX' || dx_pos
    FROM (
        UNPIVOT stg.claim_line ON dx1, dx2, dx3 INTO NAME dx_slot VALUE dx
    ) u, (SELECT right(u.dx_slot, 1) AS dx_pos)
    WHERE dx IS NOT NULL AND dx <> ''
)
SELECT * FROM long;
