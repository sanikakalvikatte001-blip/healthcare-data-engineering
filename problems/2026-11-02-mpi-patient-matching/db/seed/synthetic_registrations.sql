-- =============================================================================
-- Synthetic registration feed (NO real PHI)
--
-- Builds 410 made-up people, then emits registration messages from three
-- sources the way real feeds look: different formats, nicknames, typos,
-- swapped DOBs, missing / placeholder SSNs, surname changes, moves, duplicate
-- charts, plus the classic hard negatives (twins, Jr/Sr at one address).
--   B20261101 : EHR_EPIC   - initial chart load
--   B20261102 : LAB_LIS + CLAIMS_PAYER + EHR resends
-- SSNs are in the never-issued 9xx range; phones use the fictional 555-01xx.
-- setseed() makes the run reproducible.
-- =============================================================================

SELECT setseed(0.20261102);

TRUNCATE stg.patient_registration, stg.synthetic_truth, stg.synthetic_person RESTART IDENTITY;

-- -----------------------------------------------------------------------------
-- 1. People
-- -----------------------------------------------------------------------------
INSERT INTO stg.synthetic_person
WITH lists AS (
    SELECT ARRAY['MARY','PATRICIA','JENNIFER','ELIZABETH','SUSAN','MARGARET','KATHERINE','ABIGAIL',
                 'LINDA','BARBARA','SARAH','KAREN','NANCY','LISA','DIANA','EMILY','RACHEL','GRACE']     AS fem,
           ARRAY['JAMES','ROBERT','WILLIAM','MICHAEL','THOMAS','RICHARD','JOSEPH','DANIEL','DAVID',
                 'STEVEN','CHRISTOPHER','MATTHEW','ANTHONY','EDWARD','SAMUEL','NICHOLAS','GEORGE','KEVIN'] AS mal,
           ARRAY['ANDERSON','BRENNAN','CASTILLO','DONOVAN','ELLISON','FERREIRA','GALLAGHER','HARRINGTON',
                 'IVANOV','JOHANSSON','KOWALSKI','LINDQVIST','MARTINEZ','NAKAMURA','OKAFOR','PETERSEN',
                 'QUINTERO','ROSSITER','SANTIAGO','THORNTON','UNDERWOOD','VASQUEZ','WHITAKER','YAMAMOTO',
                 'ZIELINSKI','ABERNATHY','BLACKWELL','CALLOWAY','DESMOND','FAIRBANKS','GREENFIELD',
                 'HOLLOWAY','KINCAID','LOCKHART','MERCADO','NORDSTROM','PEMBERTON','RADCLIFFE',
                 'SINCLAIR','TREMBLAY']                                                                  AS lastn,
           ARRAY['MAPLE','OAK','CEDAR','ELM','BIRCH','WILLOW','LAKEVIEW','HILLCREST','RIVER','SUNSET',
                 'PARK','MEADOW','CHESTNUT','HIGHLAND','ORCHARD']                                       AS street,
           ARRAY['STREET','AVENUE','ROAD','DRIVE','LANE','BOULEVARD']                                   AS stype,
           ARRAY['212','315','518','607','716','845','914','631','585','347']                           AS area
),
base AS (       -- 360 independent people
    SELECT g AS person_id,
           CASE WHEN random() < 0.5 THEN 'F' ELSE 'M' END AS sex,
           random() AS r_first, random() AS r_last, random() AS r_dob,
           random() AS r_st, random() AS r_num, random() AS r_type, random() AS r_zip,
           random() AS r_area, random() AS r_ph, random() AS r_ssn
    FROM generate_series(1, 360) g
)
SELECT b.person_id, b.sex,
       CASE WHEN b.sex = 'F' THEN l.fem[1 + floor(b.r_first * array_length(l.fem, 1))::int]
            ELSE l.mal[1 + floor(b.r_first * array_length(l.mal, 1))::int] END       AS first_name,
       l.lastn[1 + floor(b.r_last * array_length(l.lastn, 1))::int]                 AS last_name,
       (date '1940-01-01' + floor(b.r_dob * 365 * 80)::int)                         AS birth_date,
       (900 + b.person_id % 100)::text || '-' || (10 + b.person_id / 100)::text
           || '-' || (1000 + floor(b.r_ssn * 9000)::int)::text                      AS ssn,
       l.area[1 + floor(b.r_area * 10)::int] || '5550' || lpad((100 + floor(b.r_ph * 100)::int)::text, 3, '0') AS phone,
       (10 + floor(b.r_num * 9900)::int)::text || ' '
           || l.street[1 + floor(b.r_st * array_length(l.street, 1))::int] || ' '
           || l.stype[1 + floor(b.r_type * array_length(l.stype, 1))::int]          AS address_line,
       (12000 + floor(b.r_zip * 2000)::int)::text                                   AS zip,
       'independent'::text                                                           AS family_role
FROM base b CROSS JOIN lists l;

-- 15 sets of twins: same surname, DOB, address and phone; different first
-- name and SSN. A matcher that leans on DOB + address will wrongly merge them.
INSERT INTO stg.synthetic_person
SELECT 360 + row_number() OVER (ORDER BY p.person_id),
       p.sex,
       CASE WHEN p.sex = 'F' THEN (ARRAY['OLIVIA','HANNAH','CLAIRE','NATALIE','VICTORIA'])[1 + p.person_id % 5]
            ELSE (ARRAY['ETHAN','LUCAS','OWEN','HENRY','CALEB'])[1 + p.person_id % 5] END,
       p.last_name, p.birth_date,
       (900 + (360 + row_number() OVER (ORDER BY p.person_id)) % 100)::text || '-'
           || (10 + (360 + row_number() OVER (ORDER BY p.person_id)) / 100)::text || '-' || '4321',
       p.phone, p.address_line, p.zip, 'twin_of_' || p.person_id
FROM stg.synthetic_person p
WHERE p.person_id BETWEEN 1 AND 15;

-- 10 father/son pairs (Jr/Sr): same first and last name, address and phone,
-- DOB ~28 years apart, different SSN.
INSERT INTO stg.synthetic_person
SELECT 375 + row_number() OVER (ORDER BY p.person_id),
       'M', p.first_name, p.last_name, p.birth_date + 28 * 365,
       (900 + (375 + row_number() OVER (ORDER BY p.person_id)) % 100)::text || '-'
           || (10 + (375 + row_number() OVER (ORDER BY p.person_id)) / 100)::text || '-' || '8765',
       p.phone, p.address_line, p.zip, 'junior_of_' || p.person_id
FROM stg.synthetic_person p
WHERE p.sex = 'M' AND p.person_id BETWEEN 16 AND 200 AND p.birth_date < date '1975-01-01'
ORDER BY p.person_id
LIMIT 10;

-- -----------------------------------------------------------------------------
-- 2. Batch B20261101 - EHR initial load. Clean-ish, initcap names, ISO dates.
-- -----------------------------------------------------------------------------
INSERT INTO stg.patient_registration
    (batch_id, source_system, source_patient_id, first_name, middle_name, last_name,
     birth_date_raw, sex_raw, ssn_raw, phone_raw, address_line, zip_raw, received_at)
SELECT 'B20261101', 'EHR_EPIC', 'E' || lpad(p.person_id::text, 6, '0'),
       initcap(p.first_name), NULL,
       initcap(p.last_name) || CASE WHEN p.family_role LIKE 'junior_of_%' THEN ' Jr.' ELSE '' END,
       to_char(p.birth_date, 'YYYY-MM-DD'), p.sex,
       CASE WHEN random() < 0.90 THEN p.ssn END,
       '(' || substr(p.phone, 1, 3) || ') ' || substr(p.phone, 4, 3) || '-' || substr(p.phone, 7, 4),
       initcap(p.address_line), p.zip,
       timestamptz '2026-11-01 06:00:00+00' + p.person_id * interval '1 minute'
FROM stg.synthetic_person p
WHERE p.person_id NOT BETWEEN 341 AND 355;     -- 15 people seen first by lab / payer

INSERT INTO stg.synthetic_truth
SELECT 'EHR_EPIC', 'E' || lpad(person_id::text, 6, '0'), person_id,
       CASE WHEN family_role LIKE 'twin%' THEN 'twin' WHEN family_role LIKE 'junior%' THEN 'jr_sr' ELSE 'clean' END
FROM stg.synthetic_person
WHERE person_id NOT BETWEEN 341 AND 355;

-- 12 duplicate charts: registrar missed the existing MRN and created a new
-- one (nickname, no SSN). Persons 201-212.
INSERT INTO stg.patient_registration
    (batch_id, source_system, source_patient_id, first_name, last_name, birth_date_raw,
     sex_raw, ssn_raw, phone_raw, address_line, zip_raw, received_at)
SELECT 'B20261101', 'EHR_EPIC', 'E9' || lpad(p.person_id::text, 5, '0'),
       coalesce((SELECT initcap(min(n.nickname)) FROM mpi.nickname n WHERE n.canonical = p.first_name),
                initcap(p.first_name)),
       initcap(p.last_name), to_char(p.birth_date, 'YYYY-MM-DD'), p.sex, NULL,
       p.phone, initcap(p.address_line), p.zip,
       timestamptz '2026-11-01 18:00:00+00' + p.person_id * interval '1 minute'
FROM stg.synthetic_person p
WHERE p.person_id BETWEEN 201 AND 212;

INSERT INTO stg.synthetic_truth
SELECT 'EHR_EPIC', 'E9' || lpad(person_id::text, 5, '0'), person_id, 'same_source_dup'
FROM stg.synthetic_person WHERE person_id BETWEEN 201 AND 212;

-- 3 unusable rows (rejected, not matched)
INSERT INTO stg.patient_registration
    (batch_id, source_system, source_patient_id, first_name, last_name, birth_date_raw, sex_raw, received_at)
VALUES ('B20261101', 'EHR_EPIC', 'E999901', 'Unknown', '',          '1980-05-05', 'U', '2026-11-01 23:00+00'),
       ('B20261101', 'EHR_EPIC', 'E999902', 'Baby Boy', 'Okafor',   '1985-02-30', 'M', '2026-11-01 23:01+00'),
       ('B20261101', 'EHR_EPIC', 'E999903', 'Grace',    'Sinclair', 'unknown',    'F', '2026-11-01 23:02+00');

-- -----------------------------------------------------------------------------
-- 3. Batch B20261102 - LAB_LIS: upper-case names, MM/DD/YYYY, SSN usually
--    absent, nicknames, typos and swapped DOBs.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE lab_pick AS
SELECT p.*,
       random() AS r_nick, random() AS r_typo, random() AS r_swap, random() AS r_ssn, random() AS r_min
FROM stg.synthetic_person p
WHERE random() < 0.60 OR p.person_id BETWEEN 341 AND 355;

INSERT INTO stg.synthetic_truth
SELECT 'LAB_LIS', 'L' || lpad((p.person_id * 7)::text, 7, '0'), p.person_id,
       coalesce(NULLIF(concat_ws('+',
           CASE WHEN p.family_role LIKE 'twin%' THEN 'twin' WHEN p.family_role LIKE 'junior%' THEN 'jr_sr' END,
           CASE WHEN p.r_nick < 0.25 AND EXISTS (SELECT 1 FROM mpi.nickname n WHERE n.canonical = p.first_name) THEN 'nickname' END,
           CASE WHEN p.r_typo < 0.10 THEN 'last_typo' END,
           CASE WHEN p.r_swap < 0.08 AND extract(day FROM p.birth_date) <= 12
                 AND extract(day FROM p.birth_date) <> extract(month FROM p.birth_date) THEN 'dob_swap' END,
           CASE WHEN p.r_min < 0.10 THEN 'minimal_demographics' END,
           CASE WHEN p.r_ssn >= 0.20 THEN 'no_ssn' END), ''), 'clean')
FROM lab_pick p;

INSERT INTO stg.patient_registration
    (batch_id, source_system, source_patient_id, first_name, last_name, birth_date_raw,
     sex_raw, ssn_raw, phone_raw, address_line, zip_raw, received_at)
SELECT 'B20261102', 'LAB_LIS', 'L' || lpad((p.person_id * 7)::text, 7, '0'),
       CASE WHEN p.r_nick < 0.25
            THEN coalesce((SELECT max(n.nickname) FROM mpi.nickname n WHERE n.canonical = p.first_name), p.first_name)
            ELSE p.first_name END,
       CASE WHEN p.r_typo < 0.10      -- swap 2nd and 3rd letters: SANTIAGO -> SNATIAGO
            THEN left(p.last_name, 1) || substr(p.last_name, 3, 1) || substr(p.last_name, 2, 1) || substr(p.last_name, 4)
            ELSE p.last_name END,
       to_char(CASE WHEN p.r_swap < 0.08 AND extract(day FROM p.birth_date) <= 12
                    THEN make_date(extract(year FROM p.birth_date)::int,
                                   extract(day FROM p.birth_date)::int,
                                   extract(month FROM p.birth_date)::int)
                    ELSE p.birth_date END, 'MM/DD/YYYY'),
       CASE p.sex WHEN 'F' THEN 'Female' ELSE 'Male' END,
       CASE WHEN p.r_ssn < 0.20 THEN replace(p.ssn, '-', '') END,
       CASE WHEN p.r_min >= 0.10 THEN p.phone END,            -- walk-in lab orders often
       CASE WHEN p.r_min >= 0.10                               -- carry no phone / address
            THEN replace(replace(p.address_line, 'STREET', 'ST'), 'AVENUE', 'AVE.') END,
       CASE WHEN p.r_min >= 0.10 THEN p.zip || '-0001' END,
       timestamptz '2026-11-02 05:00:00+00' + p.person_id * interval '1 minute'
FROM lab_pick p;

-- -----------------------------------------------------------------------------
-- 4. Batch B20261102 - CLAIMS_PAYER (834/837 member demographics): X12 date
--    format, numeric sex, placeholder SSNs, surname changes and moves.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE claims_pick AS
SELECT p.*,
       random() AS r_ph, random() AS r_name, random() AS r_move, random() AS r_new
FROM stg.synthetic_person p
WHERE random() < 0.50 OR p.person_id BETWEEN 341 AND 355;

INSERT INTO stg.synthetic_truth
SELECT 'CLAIMS_PAYER', 'M' || lpad((p.person_id * 13)::text, 8, '0'), p.person_id,
       coalesce(NULLIF(concat_ws('+',
           CASE WHEN p.family_role LIKE 'twin%' THEN 'twin' WHEN p.family_role LIKE 'junior%' THEN 'jr_sr' END,
           CASE WHEN p.r_ph < 0.05 THEN 'placeholder_ssn' END,
           CASE WHEN p.sex = 'F' AND p.r_name < 0.12 THEN 'name_change' END,
           CASE WHEN p.r_move < 0.10 THEN 'moved' END), ''), 'clean')
FROM claims_pick p;

INSERT INTO stg.patient_registration
    (batch_id, source_system, source_patient_id, first_name, last_name, birth_date_raw,
     sex_raw, ssn_raw, phone_raw, address_line, zip_raw, received_at)
SELECT 'B20261102', 'CLAIMS_PAYER', 'M' || lpad((p.person_id * 13)::text, 8, '0'),
       p.first_name,
       CASE WHEN p.sex = 'F' AND p.r_name < 0.12
            THEN (ARRAY['HARTWELL','MONTGOMERY','ASHWORTH','BRADSHAW'])[1 + floor(p.r_new * 4)::int]
            ELSE p.last_name END,
       to_char(p.birth_date, 'YYYYMMDD'),
       CASE p.sex WHEN 'M' THEN '1' ELSE '2' END,
       CASE WHEN p.r_ph < 0.05 THEN '999999999' ELSE replace(p.ssn, '-', '') END,
       CASE WHEN p.r_move < 0.10 THEN NULL ELSE '1' || p.phone END,
       CASE WHEN p.r_move < 0.10 THEN (100 + floor(p.r_new * 800)::int)::text || ' HARBOR POINT RD'
            ELSE p.address_line END,
       CASE WHEN p.r_move < 0.10 THEN (14500 + floor(p.r_new * 300)::int)::text ELSE p.zip END,
       timestamptz '2026-11-02 07:00:00+00' + p.person_id * interval '1 minute'
FROM claims_pick p;

-- -----------------------------------------------------------------------------
-- 5. Batch B20261102 - EHR resends: 20 charts re-sent with a new phone number
--    (sent twice; the later message must win).
-- -----------------------------------------------------------------------------
INSERT INTO stg.patient_registration
    (batch_id, source_system, source_patient_id, first_name, last_name, birth_date_raw,
     sex_raw, ssn_raw, phone_raw, address_line, zip_raw, received_at)
SELECT 'B20261102', r.source_system, r.source_patient_id, r.first_name, r.last_name, r.birth_date_raw,
       r.sex_raw, r.ssn_raw,
       CASE WHEN v.n = 1 THEN '(000) 000-0000' ELSE '(646) 555-01' || lpad((r.load_id % 100)::text, 2, '0') END,
       r.address_line, r.zip_raw,
       timestamptz '2026-11-02 12:00:00+00' + v.n * interval '1 hour'
FROM stg.patient_registration r
CROSS JOIN (VALUES (1), (2)) v(n)
WHERE r.batch_id = 'B20261101' AND r.source_patient_id BETWEEN 'E000301' AND 'E000320';
