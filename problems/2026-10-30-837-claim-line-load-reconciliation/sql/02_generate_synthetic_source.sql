-- =============================================================================
-- 02_generate_synthetic_source.sql
-- Generates a synthetic 837P batch into staging. No real PHI: member ids,
-- claim ids and NPIs are made up (NPIs have valid Luhn check digits).
--
-- Deterministic: setseed() fixes random(), and every injected defect is tied
-- to a specific claim sequence number so the tests can assert exact counts.
--
--   2,000 claims x (1 + seq % 4) lines  = 5,000 service lines
--   batch B20261030, file ISA000123456, received 2026-10-28
-- =============================================================================

SELECT setseed(0.20261030);

TRUNCATE src.stg_837p_claim_line;

WITH
-- 40 synthetic providers: 9-digit base + computed Luhn check digit.
providers AS (
    SELECT p AS provider_idx,
           base9 || util.npi_check_digit(base9)::text AS npi
    FROM (SELECT p, (100000000 + p * 7919)::text AS base9   -- '1xxxxxxxx' => type 1 NPI
          FROM generate_series(1, 40) AS p) b
),
-- Reference value pools (real code values, synthetic usage).
cpt AS (
    SELECT * FROM (VALUES
        (1, '99213',  95.00), (2, '99214', 140.00), (3, '99203', 115.00),
        (4, '36415',  12.00), (5, '80053',  48.00), (6, '85025',  32.00),
        (7, '93000',  60.00), (8, '71046',  85.00), (9, '97110',  55.00),
        (10,'90471',  30.00)) AS t(idx, code, base_amt)
),
dx AS (
    SELECT * FROM (VALUES
        (1,'E119'), (2,'I10'), (3,'J069'), (4,'M545'), (5,'Z0000'),
        (6,'E785'), (7,'K219'), (8,'F329'), (9,'N390'), (10,'R519')) AS t(idx, code)
),
claims AS (
    SELECT seq,
           'CLM' || lpad(seq::text, 7, '0')                     AS claim_id,
           'M'   || lpad((1 + floor(random() * 900))::text, 6, '0') AS member_id,
           1 + floor(random() * 40)::int                        AS billing_idx,
           date '2026-07-01' + floor(random() * 117)::int       AS dos,
           (ARRAY['11','11','11','22','23','81','02'])[1 + floor(random() * 7)::int] AS pos
    FROM generate_series(1, 2000) AS seq
),
lines AS (
    SELECT c.*, l AS line_no,
           1 + floor(random() * 40)::int AS rendering_idx,
           1 + floor(random() * 10)::int AS cpt_idx,
           1 + floor(random() * 10)::int AS dx_idx,
           random()                      AS r_mod,
           1 + floor(random() * 3)::int  AS units,
           random()                      AS r_amt
    FROM claims c
    CROSS JOIN LATERAL generate_series(1, 1 + c.seq % 4) AS l
)
INSERT INTO src.stg_837p_claim_line
SELECT
    'B20261030', 'ISA000123456', '20261028',
    l.claim_id,
    l.line_no::text,
    l.member_id,
    bp.npi,
    rp.npi,
    to_char(l.dos, 'YYYYMMDD'),
    l.pos,
    -- Cosmetic noise that a correct reconciliation must NOT flag:
    -- padded CPTs and lowercase modifiers on every 10th claim.
    CASE WHEN l.seq % 10 = 0 THEN ' ' || cpt.code || ' ' ELSE cpt.code END,
    CASE WHEN l.seq BETWEEN 341 AND 344 AND l.line_no = 1 THEN '25'   -- needed for a load defect later
         WHEN l.r_mod < 0.08 THEN CASE WHEN l.seq % 10 = 0 THEN 'gt' ELSE 'GT' END
         WHEN l.r_mod < 0.15 THEN '59'
         END,
    dx.code,
    l.units::text,
    -- X12 amounts drop trailing zeros ("125.5", "48"); the warehouse stores 125.50.
    trim(trailing '.' FROM trim(trailing '0' FROM
        round((cpt.base_amt * l.units * (0.9 + l.r_amt * 0.3))::numeric, 2)::text))
FROM lines l
JOIN providers bp ON bp.provider_idx = l.billing_idx
JOIN providers rp ON rp.provider_idx = l.rendering_idx
JOIN cpt          ON cpt.idx = l.cpt_idx
JOIN dx           ON dx.idx  = l.dx_idx;

-- -----------------------------------------------------------------------------
-- Source data quality defects (what the clearinghouse let through).
-- All on line 1 of a fixed set of claims; ranges do not overlap.
-- -----------------------------------------------------------------------------

-- 6 rendering NPIs with a broken check digit (keying error).
UPDATE src.stg_837p_claim_line
SET rendering_npi = left(rendering_npi, 9) || ((right(rendering_npi, 1)::int + 1) % 10)::text
WHERE claim_id BETWEEN 'CLM0000201' AND 'CLM0000206' AND line_no = '1';

-- 5 diagnosis codes that are not valid 837 ICD-10-CM format.
UPDATE src.stg_837p_claim_line s
SET dx_code_1 = v.bad
FROM (VALUES ('CLM0000211','E11.9'), ('CLM0000212','I10.'), ('CLM0000213','999'),
             ('CLM0000214','ZZ'),    ('CLM0000215','E1')) AS v(claim_id, bad)
WHERE s.claim_id = v.claim_id AND s.line_no = '1';

-- 2 service dates after the file received date.
UPDATE src.stg_837p_claim_line
SET service_from_date = '20261105'
WHERE claim_id IN ('CLM0000221', 'CLM0000222') AND line_no = '1';

-- 3 zero / negative billed amounts.
UPDATE src.stg_837p_claim_line s
SET billed_amount = v.amt
FROM (VALUES ('CLM0000231','0'), ('CLM0000232','-25.5'), ('CLM0000233','0.00')) AS v(claim_id, amt)
WHERE s.claim_id = v.claim_id AND s.line_no = '1';

-- 2 lines with zero units.
UPDATE src.stg_837p_claim_line
SET units = '0'
WHERE claim_id IN ('CLM0000241', 'CLM0000242') AND line_no = '1';

-- 2 invalid place-of-service codes.
UPDATE src.stg_837p_claim_line s
SET place_of_service = v.pos
FROM (VALUES ('CLM0000251','99'), ('CLM0000252','AA')) AS v(claim_id, pos)
WHERE s.claim_id = v.claim_id AND s.line_no = '1';

-- 1 line with a missing subscriber id.
UPDATE src.stg_837p_claim_line
SET member_id = '  '
WHERE claim_id = 'CLM0000261' AND line_no = '1';
