-- =============================================================================
-- V003  Normalization functions
--
-- Each source formats demographics its own way. Matching only works after
-- every field is reduced to one canonical form. All functions return NULL for
-- values that carry no identity information (placeholders, junk).
-- =============================================================================

-- Names: upper case, drop generational suffixes, keep letters only.
--   "o'brien jr." -> OBRIEN,  "Mary-Ann" -> MARYANN
CREATE FUNCTION util.norm_name(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(
             regexp_replace(
               regexp_replace(upper(trim(p)), '[\s,]+(JR|SR|II|III|IV)\.?$', ''),
               '[^A-Z]', '', 'g'),
             '')
$$;

-- Given name with nickname resolved: BOB -> ROBERT.
CREATE FUNCTION util.canon_first(p text) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT n.canonical FROM mpi.nickname n WHERE n.nickname = util.norm_name(p)),
                    util.norm_name(p))
$$;

-- Dates of birth arrive as YYYY-MM-DD (EHR), MM/DD/YYYY (lab), YYYYMMDD (X12).
-- Impossible dates (Feb 30), future dates and pre-1900 dates return NULL.
CREATE FUNCTION util.parse_dob(p text) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    s text := trim(p);
    y int; m int; d int;
    result date;
BEGIN
    IF s ~ '^\d{4}-\d{1,2}-\d{1,2}$' THEN
        y := split_part(s, '-', 1)::int; m := split_part(s, '-', 2)::int; d := split_part(s, '-', 3)::int;
    ELSIF s ~ '^\d{1,2}/\d{1,2}/\d{4}$' THEN
        m := split_part(s, '/', 1)::int; d := split_part(s, '/', 2)::int; y := split_part(s, '/', 3)::int;
    ELSIF s ~ '^\d{8}$' THEN
        y := substr(s, 1, 4)::int; m := substr(s, 5, 2)::int; d := substr(s, 7, 2)::int;
    ELSE
        RETURN NULL;
    END IF;

    BEGIN
        result := make_date(y, m, d);
    EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
        RETURN NULL;
    END;

    IF result < date '1900-01-01' OR result > current_date THEN
        RETURN NULL;
    END IF;
    RETURN result;
END $$;

-- SSN: nine digits, and not one of the values registration clerks type when
-- the patient has none (000-00-0000, 123-45-6789, 999-99-9999 ...).
-- Never-issued area 000 / 666, group 00 and serial 0000 are rejected too.
CREATE FUNCTION util.norm_ssn(p text) RETURNS char(9)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN s !~ '^\d{9}$'                        THEN NULL
             WHEN s ~ '^(\d)\1{8}$'                     THEN NULL   -- all one digit
             WHEN s IN ('123456789', '987654321')       THEN NULL
             WHEN substr(s, 1, 3) IN ('000', '666')     THEN NULL
             WHEN substr(s, 4, 2) = '00'                THEN NULL
             WHEN substr(s, 6, 4) = '0000'              THEN NULL
             ELSE s
           END
    FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS s) x
$$;

-- Phone: 10 digits, leading country code 1 dropped.
CREATE FUNCTION util.norm_phone(p text) RETURNS char(10)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN length(s) = 11 AND left(s, 1) = '1' THEN right(s, 10)
             WHEN length(s) = 10 AND s !~ '^(\d)\1{9}$' THEN s
           END
    FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS s) x
$$;

-- Administrative sex: HL7 (M/F/U), spelled out, or X12 numeric (1/2).
CREATE FUNCTION util.norm_sex(p text) RETURNS char(1)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE upper(trim(p))
             WHEN 'M' THEN 'M' WHEN 'MALE'   THEN 'M' WHEN '1' THEN 'M'
             WHEN 'F' THEN 'F' WHEN 'FEMALE' THEN 'F' WHEN '2' THEN 'F'
           END
$$;

CREATE FUNCTION util.norm_zip(p text) RETURNS char(5)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN s ~ '^\d{5}' AND left(s, 5) <> '00000' THEN left(s, 5) END
    FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS s) x
$$;

-- Street address: upper case, punctuation removed, USPS-style abbreviations.
CREATE FUNCTION util.norm_address(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(trim(regexp_replace(a, '\s+', ' ', 'g')), '')
    FROM (
        SELECT regexp_replace(regexp_replace(regexp_replace(regexp_replace(
               regexp_replace(regexp_replace(regexp_replace(
                   regexp_replace(upper(coalesce(p, '')), '[.,#]', ' ', 'g'),
               '\mSTREET\M',    'ST',  'g'),
               '\mAVENUE\M',    'AVE', 'g'),
               '\mROAD\M',      'RD',  'g'),
               '\mDRIVE\M',     'DR',  'g'),
               '\mLANE\M',      'LN',  'g'),
               '\mAPARTMENT\M', 'APT', 'g'),
               '\mBOULEVARD\M', 'BLVD','g') AS a
    ) x
$$;
