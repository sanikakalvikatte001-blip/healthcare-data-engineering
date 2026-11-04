-- =============================================================================
-- seeds/generate_synthetic_sources.sql
-- Builds the RAW layer with 100% synthetic data (no PHI, NPIs are fake).
--
-- raw.provider_roster_snapshot : monthly provider roster files (like a payer's
--                                credentialing / network extract), Jan-Dec 2025
-- raw.member                   : member eligibility header (Type 1, small)
-- raw.claim_line               : professional claim lines incl. replacements,
--                                voids and duplicate re-sends
--
-- Randomness is avoided on purpose: every value is a pure function of the row
-- number (modulo arithmetic), so the build is byte-for-byte reproducible.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS raw;

-- -----------------------------------------------------------------------------
-- 1. Provider master (the "truth" we use to generate monthly files)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE gen_provider AS
SELECT
    p                                                        AS p,
    -- synthetic 10-digit NPI-shaped identifier (not a real NPI)
    (1990000000 + p * 7919)::VARCHAR                         AS npi,
    ['SMITH','PATEL','NGUYEN','GARCIA','KIM','JOHNSON','OKAFOR','ROSSI',
     'COHEN','SILVA','MULLER','TANAKA'][1 + (p % 12)]        AS last_name,
    ['ANNA','RAVI','MINH','LUIS','JIN','MARY','CHIDI','MARCO','LEAH','ANA']
        [1 + (p % 10)]                                       AS first_name,
    -- base taxonomy / specialty
    [['207Q00000X', 'Family Medicine'],
     ['207R00000X', 'Internal Medicine'],
     ['208000000X', 'Pediatrics'],
     ['207RC0000X', 'Cardiovascular Disease'],
     ['207X00000X', 'Orthopaedic Surgery'],
     ['2084P0800X', 'Psychiatry'],
     ['207V00000X', 'Obstetrics & Gynecology'],
     ['207N00000X', 'Dermatology']][1 + (p % 8)]              AS base_specialty,
    CASE WHEN p % 10 = 0 THEN 'OUT' ELSE 'IN' END            AS base_network,
    '84-' || lpad((1000000 + (p % 6) * 1111)::VARCHAR, 7, '0') AS base_tin,
    -- providers 56-60 are credentialed mid-year (first file = June 2025)
    CASE WHEN p > 55 THEN 6 ELSE 1 END                       AS first_month,
    -- providers 50-52 leave the network: absent from Oct 2025 onward
    CASE WHEN p BETWEEN 50 AND 52 THEN 9 ELSE 12 END         AS last_month
FROM range(1, 61) t(p);

-- -----------------------------------------------------------------------------
-- 2. Monthly roster snapshots with real-world change patterns and noise
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE raw.provider_roster_snapshot AS
WITH grid AS (
    SELECT g.*, m AS month_no, make_date(2025, m::INT, 1) AS snapshot_date
    FROM gen_provider g
    CROSS JOIN range(1, 13) r(m)
    WHERE m BETWEEN g.first_month AND g.last_month
      -- p % 17 = 0: provider silently missing from the September file only
      AND NOT (g.p % 17 = 0 AND m = 9)
),
attrs AS (
    SELECT
        *,
        -- network change: p % 7 = 0 flips network status from month (p % 6) + 3
        CASE
            WHEN p % 7 = 0 AND month_no >= (p % 6) + 3
                 THEN CASE base_network WHEN 'IN' THEN 'OUT' ELSE 'IN' END
            -- p % 13 = 0: OUT for May-June only, then back IN (A -> B -> A)
            WHEN p % 13 = 0 AND month_no IN (5, 6) THEN 'OUT'
            ELSE base_network
        END AS network_status,
        -- specialty change (e.g. fellowship completed) from July
        CASE WHEN p % 11 = 0 AND month_no >= 7
             THEN ['207RI0011X', 'Interventional Cardiology']
             ELSE base_specialty END AS spec,
        -- group acquisition: billing TIN changes from April
        CASE WHEN p % 9 = 0 AND month_no >= 4
             THEN '84-9990000' ELSE base_tin END AS group_tin
    FROM grid
)
SELECT
    snapshot_date,
    -- file load timestamp: 3rd of the following month
    (snapshot_date + INTERVAL 1 MONTH + INTERVAL 2 DAY)::TIMESTAMP AS load_ts,
    npi,
    -- cosmetic noise every 4th month: mixed case + padding. Must NOT create
    -- a new SCD2 version once normalized in staging.
    CASE WHEN month_no % 4 = 0 AND p % 3 = 0
         THEN '  ' || (left(last_name, 1) || lower(substr(last_name, 2))) || ' ' ELSE last_name END AS provider_last_name,
    CASE WHEN month_no % 4 = 0 AND p % 3 = 0
         THEN lower(first_name) ELSE first_name END               AS provider_first_name,
    spec[1]                                                       AS taxonomy_code,
    spec[2]                                                       AS specialty_desc,
    -- some feeds send network status in lower case
    CASE WHEN month_no = 3 THEN lower(network_status) ELSE network_status END
                                                                  AS network_status,
    group_tin
FROM attrs;

-- Duplicate rows inside a single file (vendor re-sent part of March)
INSERT INTO raw.provider_roster_snapshot
SELECT * FROM raw.provider_roster_snapshot
WHERE snapshot_date = DATE '2025-03-01' AND (npi::BIGINT % 5) = 0;

-- Re-delivered August file (later load_ts). It corrects provider p = 22
-- (npi 1990174218): the first August file wrongly showed OUT of network.
UPDATE raw.provider_roster_snapshot
SET network_status = 'OUT'
WHERE snapshot_date = DATE '2025-08-01' AND npi = '1990174218';

INSERT INTO raw.provider_roster_snapshot
SELECT snapshot_date,
       load_ts + INTERVAL 5 DAY AS load_ts,
       npi, provider_last_name, provider_first_name, taxonomy_code,
       specialty_desc,
       CASE WHEN npi = '1990174218' THEN 'IN' ELSE network_status END,
       group_tin
FROM raw.provider_roster_snapshot
WHERE snapshot_date = DATE '2025-08-01';

-- -----------------------------------------------------------------------------
-- 3. Members (Type 1 header, 400 members)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE raw.member AS
SELECT
    'M' || lpad(m::VARCHAR, 6, '0')                        AS member_id,
    make_date(1940 + (m * 37) % 70, 1 + (m % 12)::INT, 1 + (m % 28)::INT) AS birth_date,
    CASE m % 2 WHEN 0 THEN 'F' ELSE 'M' END                AS gender,
    ['COMMERCIAL','MEDICARE ADV','MEDICAID'][1 + (m % 3)]  AS line_of_business
FROM range(1, 401) t(m);

-- -----------------------------------------------------------------------------
-- 4. Claim lines (2,400 original claims x 1-3 lines)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE gen_claim AS
SELECT
    c,
    'CLM' || lpad(c::VARCHAR, 7, '0')                            AS claim_id,
    'M' || lpad((1 + (c * 131) % 400)::VARCHAR, 6, '0')          AS member_id,
    -- rendering provider: 1..62 ; 61 and 62 are NPIs never on any roster
    1 + (c * 37) % 62                                            AS p,
    DATE '2025-01-01' + ((c * 53 + (c // 62) * 89) % 365)::INT     AS service_date,
    1 + (c % 3)                                                  AS line_count
FROM range(1, 2401) t(c);

CREATE OR REPLACE TABLE raw.claim_line AS
WITH lines AS (
    SELECT g.*, l AS line_no
    FROM gen_claim g CROSS JOIN range(1, 4) r(l)
    WHERE l <= g.line_count
),
priced AS (
    SELECT
        *,
        ['99213','99214','99203','93000','80053','20610','90834','11102']
            [1 + ((c + line_no) % 8)]                            AS cpt_code,
        round(40 + ((c * 17 + line_no * 29) % 260) + ((c % 7) * 0.25), 2) AS allowed_amt
    FROM lines
)
-- original submissions (frequency code 1)
SELECT
    claim_id, line_no, '1' AS claim_freq_code, member_id,
    CASE WHEN p <= 60 THEN (1990000000 + p * 7919)::VARCHAR
         ELSE (1880000000 + p)::VARCHAR END                      AS rendering_npi,
    service_date,
    service_date + (12 + (c % 50))::INT                          AS paid_date,
    cpt_code,
    allowed_amt,
    round(allowed_amt * 0.8, 2)                                  AS paid_amt,
    (service_date + (10 + (c % 50))::INT)::TIMESTAMP             AS received_ts
FROM priced;

-- Replacement claims (freq 7): every 25th claim re-priced 30 days later
INSERT INTO raw.claim_line
SELECT claim_id, line_no, '7', member_id, rendering_npi, service_date,
       paid_date + 30, cpt_code, allowed_amt + 15, round((allowed_amt + 15) * 0.8, 2),
       received_ts + INTERVAL 30 DAY
FROM raw.claim_line
WHERE claim_freq_code = '1' AND substr(claim_id, 4)::INT % 25 = 0;

-- Voids (freq 8): every 40th claim is voided 45 days later (zero dollars)
INSERT INTO raw.claim_line
SELECT claim_id, line_no, '8', member_id, rendering_npi, service_date,
       paid_date + 45, cpt_code, 0, 0, received_ts + INTERVAL 45 DAY
FROM raw.claim_line
WHERE claim_freq_code = '1' AND substr(claim_id, 4)::INT % 40 = 0;

-- Exact duplicate re-sends of the original (clearinghouse retry)
INSERT INTO raw.claim_line
SELECT * FROM raw.claim_line
WHERE claim_freq_code = '1' AND substr(claim_id, 4)::INT % 50 = 0;
