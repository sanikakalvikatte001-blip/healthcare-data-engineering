-- =============================================================================
-- V004  Field comparators, pair scoring and blocking keys
--
-- Comparators return one of AGREE / PARTIAL / DISAGREE / MISSING. Weights for
-- those outcomes live in mpi.match_weight, so tuning never touches code.
-- =============================================================================

-- Names: exact, close (typo or sounds-alike), or different.
-- A swap of two adjacent letters is Levenshtein distance 2, so longer names
-- tolerate 2 edits; short names only 1 (LEE vs LI should not look close).
CREATE FUNCTION util.cmp_name(a text, b text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN a IS NULL OR b IS NULL THEN 'MISSING'
             WHEN a = b THEN 'AGREE'
             WHEN levenshtein(a, b) <= CASE WHEN least(length(a), length(b)) >= 5 THEN 2 ELSE 1 END
               OR dmetaphone(a) = dmetaphone(b) THEN 'PARTIAL'
             ELSE 'DISAGREE'
           END
$$;

-- DOB: PARTIAL covers the two classic keying errors - day/month swapped
-- (US vs. international order) and exactly one component wrong.
CREATE FUNCTION util.cmp_dob(a date, b date) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN a IS NULL OR b IS NULL THEN 'MISSING'
             WHEN a = b THEN 'AGREE'
             WHEN extract(year FROM a) = extract(year FROM b)
              AND extract(month FROM a) = extract(day FROM b)
              AND extract(day FROM a)   = extract(month FROM b) THEN 'PARTIAL'
             WHEN (extract(year  FROM a) = extract(year  FROM b))::int
                + (extract(month FROM a) = extract(month FROM b))::int
                + (extract(day   FROM a) = extract(day   FROM b))::int = 2 THEN 'PARTIAL'
             ELSE 'DISAGREE'
           END
$$;

-- SSN: one mistyped digit is PARTIAL, anything else is a real disagreement.
CREATE FUNCTION util.cmp_ssn(a text, b text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN a IS NULL OR b IS NULL THEN 'MISSING'
             WHEN a = b THEN 'AGREE'
             WHEN levenshtein(a, b) = 1 THEN 'PARTIAL'
             ELSE 'DISAGREE'
           END
$$;

-- Generic equality comparator for sex, phone, ZIP.
CREATE FUNCTION util.cmp_exact(a text, b text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN a IS NULL OR b IS NULL THEN 'MISSING'
                WHEN a = b THEN 'AGREE' ELSE 'DISAGREE' END
$$;

-- Address: trigram similarity tolerates abbreviations and apartment noise.
CREATE FUNCTION util.cmp_address(a text, b text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN a IS NULL OR b IS NULL THEN 'MISSING'
                WHEN similarity(a, b) >= 0.8 THEN 'AGREE'
                WHEN similarity(a, b) >= 0.5 THEN 'PARTIAL'
                ELSE 'DISAGREE' END
$$;

-- -----------------------------------------------------------------------------
-- Score one pair of normalized source records. Returns each field outcome and
-- the summed weight, so every link decision can be explained later.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mpi.score_pair(a mpi.source_patient, b mpi.source_patient)
RETURNS TABLE (last_cmp text, first_cmp text, dob_cmp text, ssn_cmp text,
               sex_cmp text, phone_cmp text, zip_cmp text, addr_cmp text,
               total_weight numeric)
LANGUAGE sql STABLE AS $$
    WITH c AS (
        SELECT util.cmp_name(a.last_name, b.last_name)               AS last_cmp,
               util.cmp_name(a.first_name_canon, b.first_name_canon) AS first_cmp,
               util.cmp_dob(a.birth_date, b.birth_date)              AS dob_cmp,
               util.cmp_ssn(a.ssn, b.ssn)                            AS ssn_cmp,
               util.cmp_exact(a.sex, b.sex)                          AS sex_cmp,
               util.cmp_exact(a.phone, b.phone)                      AS phone_cmp,
               util.cmp_exact(a.zip5, b.zip5)                        AS zip_cmp,
               util.cmp_address(a.address_norm, b.address_norm)      AS addr_cmp
    )
    SELECT c.*,
           (SELECT sum(w.weight)
              FROM (VALUES ('last', c.last_cmp), ('first', c.first_cmp), ('dob', c.dob_cmp),
                           ('ssn', c.ssn_cmp), ('sex', c.sex_cmp), ('phone', c.phone_cmp),
                           ('zip', c.zip_cmp), ('addr', c.addr_cmp)) f(field, outcome)
              JOIN mpi.match_weight w USING (field, outcome))
    FROM c
$$;

-- -----------------------------------------------------------------------------
-- Blocking keys. Comparing every record to every other is O(n^2); blocking
-- only compares records that share a cheap key. Several overlapping keys keep
-- recall high: a DOB typo is still caught by SSN, phone or name+ZIP.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mpi.block_keys(sp mpi.source_patient) RETURNS SETOF text
LANGUAGE sql IMMUTABLE AS $$
    SELECT k FROM (VALUES
        ('DOB_LN:'   || sp.birth_date || ':' || soundex(sp.last_name)),
        ('DOB_FN:'   || sp.birth_date || ':' || dmetaphone(sp.first_name_canon)),
        ('SSN:'      || sp.ssn),
        ('PHONE:'    || sp.phone),
        ('NAME_ZIP:' || soundex(sp.last_name) || ':' || soundex(sp.first_name_canon) || ':' || sp.zip5)
    ) v(k)
    WHERE k IS NOT NULL     -- a NULL component makes the whole key NULL: no key
$$;
