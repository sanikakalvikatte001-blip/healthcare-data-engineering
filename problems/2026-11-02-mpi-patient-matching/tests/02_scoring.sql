-- pgTAP: comparators, pair scoring and blocking keys
BEGIN;
SELECT plan(15);

-- Build an in-memory normalized record without touching any table.
CREATE FUNCTION pg_temp.rec(fn text, ln text, dob date, sex char, ssn text,
                            phone text, addr text, zip text)
RETURNS mpi.source_patient LANGUAGE sql AS $$
    SELECT ROW('TEST', md5(random()::text), NULL,
               util.norm_name(fn), util.canon_first(fn), util.norm_name(ln), dob, sex,
               util.norm_ssn(ssn), util.norm_phone(phone), util.norm_address(addr),
               util.norm_zip(zip), 'h', 'T', 'T', true)::mpi.source_patient
$$;

CREATE FUNCTION pg_temp.w(a mpi.source_patient, b mpi.source_patient) RETURNS numeric
LANGUAGE sql AS $$ SELECT total_weight FROM mpi.score_pair(a, b) $$;

-- comparators
SELECT is(util.cmp_dob('1990-03-07', '1990-07-03'), 'PARTIAL',  'day/month swap is partial');
SELECT is(util.cmp_dob('1990-03-07', '1991-03-07'), 'PARTIAL',  'one component off is partial');
SELECT is(util.cmp_dob('1990-03-07', '1962-03-07'), 'PARTIAL',  'year-only difference is still one component');
SELECT is(util.cmp_dob('1990-03-07', '1962-11-21'), 'DISAGREE', 'different DOB');
SELECT is(util.cmp_name('SANTIAGO', 'SNATIAGO'),    'PARTIAL',  'adjacent-letter swap is partial');
SELECT is(util.cmp_name('SMITH', 'JONES'),          'DISAGREE', 'different names');
SELECT is(util.cmp_ssn('912345678', '912345679'),   'PARTIAL',  'one-digit SSN typo');

-- Same person: nickname, lab formatting, no SSN on the lab side -> auto-link
SELECT cmp_ok(pg_temp.w(
         pg_temp.rec('Robert', 'Kincaid', '1971-05-14', 'M', '914-10-2222', '(518) 555-0123', '12 Oak Street', '12500'),
         pg_temp.rec('BOB',    'KINCAID', '1971-05-14', 'M', NULL,          '5185550123',     '12 OAK ST',     '12500-0001')),
       '>=', 12::numeric, 'nickname + formatting differences auto-link');

-- Same person after a surname change, SSN present on both -> auto-link
SELECT cmp_ok(pg_temp.w(
         pg_temp.rec('Linda', 'Okafor',   '1983-09-02', 'F', '931-11-4444', '2125550190', '9 Elm Road', '13010'),
         pg_temp.rec('LINDA', 'HARTWELL', '19830902',   'F', '931114444',   NULL,          NULL,        '13010')),
       '>=', 12::numeric, 'married-name change still links on SSN + DOB');

-- Twins, one SSN missing: must NOT auto-link (review at most)
SELECT cmp_ok(pg_temp.w(
         pg_temp.rec('Olivia', 'Tremblay', '2001-04-04', 'F', '961-13-4321', '6075550111', '5 Birch Lane', '12700'),
         pg_temp.rec('Hannah', 'Tremblay', '2001-04-04', 'F', NULL,          '6075550111', '5 Birch Lane', '12700')),
       '<', 12::numeric, 'same-sex twins without SSN are not auto-linked');

-- Twins often get consecutive SSNs: one digit apart must not push them over
SELECT cmp_ok(pg_temp.w(
         pg_temp.rec('Olivia', 'Tremblay', '2001-04-04', 'F', '961-13-4321', '6075550111', '5 Birch Lane', '12700'),
         pg_temp.rec('Hannah', 'Tremblay', '2001-04-04', 'F', '961-13-4322', '6075550111', '5 Birch Lane', '12700')),
       '<', 12::numeric, 'twins with consecutive SSNs are not auto-linked');

-- Twins with clearly different SSNs: non-match
SELECT cmp_ok(pg_temp.w(
         pg_temp.rec('Olivia', 'Tremblay', '2001-04-04', 'F', '961-13-4321', '6075550111', '5 Birch Lane', '12700'),
         pg_temp.rec('Hannah', 'Tremblay', '2001-04-04', 'F', '975-14-8765', '6075550111', '5 Birch Lane', '12700')),
       '<', 7::numeric, 'twins with different SSNs are a non-match');

-- Father / son at one address, no SSN: must NOT auto-link
SELECT cmp_ok(pg_temp.w(
         pg_temp.rec('James', 'Lockhart',     '1958-01-20', 'M', NULL, '7165550150', '40 Park Drive', '13300'),
         pg_temp.rec('James', 'Lockhart Jr.', '1986-01-13', 'M', NULL, '7165550150', '40 Park Drive', '13300')),
       '<', 12::numeric, 'Jr/Sr at the same address are not auto-linked');

-- blocking keys: NULL components produce no key
SELECT is((SELECT count(*)::int FROM mpi.block_keys(
              pg_temp.rec('Grace', 'Sinclair', '1990-01-01', 'F', NULL, NULL, NULL, NULL))),
          2, 'record with only name + DOB gets the two DOB keys');
SELECT is((SELECT count(*)::int FROM mpi.block_keys(
              pg_temp.rec('Grace', 'Sinclair', '1990-01-01', 'F', '944-12-3456', '3475550100', '1 Elm St', '12001'))),
          5, 'fully populated record gets all five keys');

SELECT * FROM finish();
ROLLBACK;
