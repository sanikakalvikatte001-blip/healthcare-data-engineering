-- =============================================================================
-- 00_raw: deterministic synthetic population (M00001-M02000).
-- No random() calls: every "dice roll" is a hash of (member_id, salt), so the
-- same rows are produced on every run and the README numbers are reproducible.
-- Distributions are loosely realistic (HTN prevalence rises with age, ~8% of
-- vitals come from the ED, a few percent of vitals are malformed, etc.).
-- =============================================================================

-- uniform [0,1) "dice" keyed by an id and a salt
CREATE OR REPLACE TEMP MACRO dice(k, salt) AS
    (hash(k || '|' || salt) % 1000000) / 1000000.0;

CREATE OR REPLACE TEMP TABLE gen_member AS
WITH base AS (
    SELECT 'M' || lpad(i::VARCHAR, 5, '0') AS member_id
    FROM range(1, 2001) t(i)
), aged AS (
    SELECT member_id,
           12 + floor(dice(member_id, 'age') * 84)::INT AS age_dec31   -- 12..95
    FROM base
)
SELECT
    member_id,
    age_dec31,
    make_date(2026 - age_dec31,
              1 + floor(dice(member_id, 'bm') * 12)::INT,
              1 + floor(dice(member_id, 'bd') * 28)::INT)          AS birth_date,
    CASE WHEN dice(member_id, 'sex') < 0.52 THEN 'F' ELSE 'M' END  AS gender,
    CASE
        WHEN age_dec31 >= 65 AND dice(member_id, 'prod') < 0.85 THEN 'MEDICARE'
        WHEN dice(member_id, 'prod') < 0.60                    THEN 'COMMERCIAL'
        ELSE 'MEDICAID'
    END                                                            AS product_line,
    '19020' || lpad((1 + floor(dice(member_id, 'pcp') * 25))::INT::VARCHAR, 5, '0') AS pcp_npi,
    '19020' || lpad((1 + floor(dice(member_id, 'pcp2') * 25))::INT::VARCHAR, 5, '0') AS pcp_npi_2,
    dice(member_id, 'cov')                                         AS cov_roll,
    -- hypertension prevalence rises with age
    dice(member_id, 'htn') < least(0.10 + age_dec31 * 0.007, 0.80) AS has_htn
FROM aged;

-- ---------------------------------------------------------------- coverage --
-- 84% continuous, 6% one mid-year gap (15-74 days), 4% termed mid-year,
-- 3% PCP change on May 1, 3% new enrollees who join after Jan 1.
CREATE OR REPLACE TEMP TABLE gen_coverage AS
WITH gap AS (
    SELECT member_id,
           DATE '2026-03-01' + floor(dice(member_id, 'gs') * 200)::INT AS gap_start,
           15 + floor(dice(member_id, 'gl') * 60)::INT                AS gap_len
    FROM gen_member
)
SELECT m.member_id, m.birth_date, m.gender, m.product_line, m.pcp_npi,
       DATE '2024-01-01' AS eff, NULL::DATE AS term
FROM gen_member m WHERE cov_roll < 0.84
UNION ALL   -- one gap: two segments
SELECT m.member_id, m.birth_date, m.gender, m.product_line, m.pcp_npi, DATE '2024-01-01', g.gap_start - 1
FROM gen_member m JOIN gap g USING (member_id) WHERE cov_roll >= 0.84 AND cov_roll < 0.90
UNION ALL
SELECT m.member_id, m.birth_date, m.gender, m.product_line, m.pcp_npi, g.gap_start + g.gap_len, NULL
FROM gen_member m JOIN gap g USING (member_id) WHERE cov_roll >= 0.84 AND cov_roll < 0.90
UNION ALL   -- termed during the measurement year
SELECT m.member_id, m.birth_date, m.gender, m.product_line, m.pcp_npi, DATE '2024-01-01',
       DATE '2026-03-01' + floor(dice(m.member_id, 'tm') * 200)::INT
FROM gen_member m WHERE cov_roll >= 0.90 AND cov_roll < 0.94
UNION ALL   -- PCP change, contiguous segments (drives an SCD2 version)
SELECT m.member_id, m.birth_date, m.gender, m.product_line, m.pcp_npi, DATE '2024-01-01', DATE '2026-04-30'
FROM gen_member m WHERE cov_roll >= 0.94 AND cov_roll < 0.97
UNION ALL
SELECT m.member_id, m.birth_date, m.gender, m.product_line, m.pcp_npi_2, DATE '2026-05-01', NULL
FROM gen_member m WHERE cov_roll >= 0.94 AND cov_roll < 0.97
UNION ALL   -- new enrollee: gap at the start of the year
SELECT m.member_id, m.birth_date, m.gender, m.product_line, m.pcp_npi,
       DATE '2026-01-15' + floor(dice(m.member_id, 'ne') * 90)::INT, NULL
FROM gen_member m WHERE cov_roll >= 0.97;

INSERT INTO raw.member_coverage
SELECT member_id, strftime(birth_date, '%Y%m%d'), gender, product_line, pcp_npi,
       strftime(eff, '%Y%m%d'), coalesce(strftime(term, '%Y%m%d'), ''),
       strftime(greatest(eff, DATE '2026-01-05'), '%Y%m%d')
FROM gen_coverage;

-- ~10% of members: the eligibility vendor resends the first segment in a later file
INSERT INTO raw.member_coverage
SELECT member_id, birth_date, gender, product_line, pcp_npi, eff_date, term_date, '20260605'
FROM raw.member_coverage
WHERE member_id LIKE 'M%' AND dice(member_id, 'resend') < 0.10 AND eff_date = '20240101';

-- ------------------------------------------------------------------ claims --
-- Visits: HTN members get 1-4 visits with I10 between 2025-01-01 and 2026-06-30
-- (about 1 in 4 get only one, so they miss the denominator); everyone gets
-- 1-2 routine visits without HTN.
CREATE OR REPLACE TEMP TABLE gen_claim AS
WITH htn_visits AS (
    SELECT member_id, unnest(range(1 + floor(dice(member_id, 'nv') * 4)::INT)) AS n
    FROM gen_member WHERE has_htn
), routine AS (
    SELECT member_id, unnest(range(1 + floor(dice(member_id, 'nr') * 2)::INT)) AS n
    FROM gen_member
), cpt2 AS (   -- 25% of HTN members also have CPT II BP codes billed on a 2026 visit
    SELECT member_id FROM gen_member WHERE has_htn AND dice(member_id, 'c2') < 0.25
)
SELECT member_id,
       DATE '2025-01-01' + floor(dice(member_id || n, 'hd') * 546)::INT AS dos,
       '11' AS pos, '9921' || (3 + floor(dice(member_id || n, 'em') * 3)::INT) AS proc,
       CASE WHEN dice(member_id || n, 'dot') < 0.5 THEN 'I10' ELSE 'I10 ' END AS dx1,
       CASE WHEN dice(member_id || n, 'd2') < 0.3 THEN 'E78.5' END       AS dx2,
       NULL AS dx3, 'HTN' AS kind, n AS seq
FROM htn_visits
UNION ALL
SELECT member_id, DATE '2025-01-01' + floor(dice(member_id || n, 'rd') * 700)::INT,
       '11', '99212', 'Z00.00', NULL, NULL, 'ROUTINE', n
FROM routine
UNION ALL   -- CPT II systolic + diastolic lines on one 2026 visit
SELECT c.member_id, DATE '2026-01-10' + floor(dice(c.member_id, 'c2d') * 330)::INT, '11',
       CASE WHEN r < 0.45 THEN '3074F' WHEN r < 0.75 THEN '3075F' ELSE '3077F' END,
       'I10', NULL, NULL, 'CPT2', 1
FROM cpt2 c, (SELECT dice(c.member_id, 'c2s') AS r)
UNION ALL
SELECT c.member_id, DATE '2026-01-10' + floor(dice(c.member_id, 'c2d') * 330)::INT, '11',
       CASE WHEN r < 0.55 THEN '3078F' WHEN r < 0.85 THEN '3079F' ELSE '3080F' END,
       'I10', NULL, NULL, 'CPT2', 2
FROM cpt2 c, (SELECT dice(c.member_id, 'c2x') AS r)
UNION ALL   -- exclusions (only meaningful for HTN members)
SELECT member_id, DATE '2026-02-01' + floor(dice(member_id, 'hx') * 250)::INT, '12', 'Q5001',
       'C34.90', NULL, NULL, 'HOSPICE', 1
FROM gen_member WHERE has_htn AND dice(member_id, 'hos') < 0.02
UNION ALL
SELECT member_id, DATE '2025-06-01' + floor(dice(member_id, 'ex') * 400)::INT, '11', '99213',
       'N18.6', NULL, NULL, 'ESRD', 1
FROM gen_member WHERE has_htn AND dice(member_id, 'esrd') < 0.025
UNION ALL
SELECT member_id, DATE '2026-01-15' + floor(dice(member_id, 'px') * 200)::INT, '11', '99213',
       'Z34.90', NULL, NULL, 'PREG', 1
FROM gen_member WHERE has_htn AND gender = 'F' AND age_dec31 BETWEEN 18 AND 44
                  AND dice(member_id, 'preg') < 0.06
UNION ALL
SELECT member_id, DATE '2026-01-15' + floor(dice(member_id, 'fx') * 300)::INT, '11', '99214',
       'R54', NULL, NULL, 'FRAIL', 1
FROM gen_member WHERE has_htn AND age_dec31 >= 66 AND dice(member_id, 'frail') < 0.20
UNION ALL
SELECT member_id, DATE '2025-01-15' + floor(dice(member_id, 'ax') * 600)::INT, '11', '99214',
       CASE WHEN dice(member_id, 'aw') < 0.5 THEN 'G30.9' ELSE 'I50.22' END, NULL, NULL, 'ADV', 1
FROM gen_member WHERE has_htn AND age_dec31 >= 66 AND dice(member_id, 'adv') < 0.12;

INSERT INTO raw.claim_lines
SELECT 'CL' || lpad(claim_no::VARCHAR, 6, '0'),
       CASE WHEN kind = 'CPT2' THEN (seq + 1)::VARCHAR ELSE '1' END,
       member_id, strftime(dos, '%Y-%m-%d'), pos, proc, dx1, dx2, dx3
FROM (
    SELECT *, dense_rank() OVER (ORDER BY member_id, dos, kind = 'CPT2', kind,
                                 CASE WHEN kind = 'CPT2' THEN 0 ELSE seq END) AS claim_no
    FROM gen_claim
);

-- ------------------------------------------------------------- EHR vitals --
-- HTN members: 0-4 BP readings in 2026 (about 1 in 5 have none). Non-HTN
-- members: 0-1 reading. ~8% of readings are in the ED (and run higher),
-- ~4% are member-reported home device readings. Formats vary by feed, and
-- ~4% of rows are malformed (0/0, swapped, "refused").
CREATE OR REPLACE TEMP TABLE gen_vital AS
WITH n AS (
    SELECT member_id, has_htn,
           CASE WHEN has_htn THEN floor(dice(member_id, 'nb') * 5)::INT
                ELSE floor(dice(member_id, 'nb') * 1.4)::INT END AS n_readings
    FROM gen_member
), r AS (
    SELECT member_id, has_htn, unnest(range(n_readings)) AS k FROM n
)
SELECT member_id, k,
       CASE WHEN s < 0.08 THEN 'ED' WHEN s < 0.12 THEN 'HOME_DEVICE'
            WHEN s < 0.15 THEN 'TELEHEALTH' ELSE 'OFFICE' END        AS setting,
       TIMESTAMP '2026-01-05 08:00:00'
         + to_days(floor(dice(member_id || k, 'vd') * 345)::INT)
         + to_minutes(floor(dice(member_id || k, 'vm') * 540)::INT) AS taken_at,
       (CASE WHEN has_htn THEN 110 ELSE 104 END)
         + floor(dice(member_id || k, 'sys') * 46)::INT
         + CASE WHEN s < 0.08 THEN 15 ELSE 0 END
         + CASE WHEN has_htn AND dice(member_id, 'severe') < 0.08 THEN 18 ELSE 0 END  -- poorly controlled
                                                                    AS sbp,
       60 + floor(dice(member_id || k, 'dia') * 33)::INT
         + CASE WHEN s < 0.08 THEN 6 ELSE 0 END
         + CASE WHEN has_htn AND dice(member_id, 'severe') < 0.08 THEN 8 ELSE 0 END
                                                                    AS dbp,
       dice(member_id || k, 'fmt')                                  AS fmt
FROM r, (SELECT dice(r.member_id || r.k, 'set') AS s);

INSERT INTO raw.ehr_vitals
SELECT 'V' || lpad(row_number() OVER (ORDER BY member_id, k)::VARCHAR, 6, '0'),
       member_id, setting, strftime(taken_at, '%Y-%m-%d %H:%M:%S'),
       CASE WHEN fmt < 0.02 THEN '0/0'
            WHEN fmt < 0.03 THEN dbp || '/' || sbp                -- swapped
            WHEN fmt < 0.04 THEN 'Pt refused'
            WHEN fmt < 0.70 THEN sbp || '/' || dbp
            WHEN fmt < 0.85 THEN sbp || ' / ' || dbp || ' mmHg'
            ELSE NULL END,                                        -- discrete columns only
       CASE WHEN fmt >= 0.85 THEN sbp::VARCHAR END,
       CASE WHEN fmt >= 0.85 THEN dbp::VARCHAR END
FROM gen_vital;
