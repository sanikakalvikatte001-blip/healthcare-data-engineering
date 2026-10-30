-- =============================================================================
-- 01_functions.sql
-- Helper functions, the normalization views, and the staging -> warehouse load.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- NPI check digit (CMS: Luhn over the 9-digit base with the 80840 prefix,
-- which always contributes a constant 24 to the sum).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION util.npi_check_digit(p_base9 text)
RETURNS integer
LANGUAGE sql IMMUTABLE STRICT AS
$$
    SELECT (10 - (24 + sum(
               CASE WHEN pos % 2 = 1                    -- positions 1,3,5,7,9 are doubled
                    THEN (d * 2) / 10 + (d * 2) % 10    -- add the digits of the product
                    ELSE d END)) % 10) % 10
    FROM (
        SELECT pos, substr(p_base9, pos, 1)::int AS d
        FROM generate_series(1, 9) AS pos
    ) digits
$$;

CREATE OR REPLACE FUNCTION util.npi_is_valid(p_npi text)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS
$$
    SELECT coalesce(
        p_npi ~ '^[12][0-9]{9}$'      -- 10 digits; type 1 or type 2 entity
        AND util.npi_check_digit(left(p_npi, 9)) = right(p_npi, 1)::int,
        false)
$$;

-- -----------------------------------------------------------------------------
-- Normalization rules shared by the load and the reconciliation, so a value is
-- only a "mismatch" when it is really different -- not because staging stores
-- ' 99213 ' / '125.5' / 'gt' and the warehouse stores '99213' / 125.50 / 'GT'.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION util.clean_code(p text)
RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT nullif(upper(btrim(p)), '') $$;

-- Expected warehouse rows, derived from staging (the "should be" side).
CREATE OR REPLACE VIEW recon.v_expected_line AS
SELECT
    s.load_batch_id,
    btrim(s.claim_id)                          AS claim_id,
    btrim(s.line_no)::int                      AS line_no,
    util.clean_code(s.member_id)               AS member_id,
    util.clean_code(s.billing_npi)             AS billing_npi,
    util.clean_code(s.rendering_npi)           AS rendering_npi,
    to_date(btrim(s.service_from_date), 'YYYYMMDD') AS service_from_date,
    util.clean_code(s.place_of_service)        AS place_of_service,
    util.clean_code(s.cpt_code)                AS cpt_code,
    util.clean_code(s.modifier_1)              AS modifier_1,
    util.clean_code(s.dx_code_1)               AS dx_code_1,
    btrim(s.units)::numeric(9,2)               AS units,
    btrim(s.billed_amount)::numeric(12,2)      AS billed_amount
FROM src.stg_837p_claim_line s;

-- Row hash over the compared columns. Both sides go through the same
-- expression so formatting differences cannot produce false mismatches.
CREATE OR REPLACE FUNCTION util.claim_line_hash(
    member_id text, billing_npi text, rendering_npi text, service_from_date date,
    place_of_service text, cpt_code text, modifier_1 text, dx_code_1 text,
    units numeric, billed_amount numeric)
RETURNS text
LANGUAGE sql IMMUTABLE AS
$$
    SELECT md5(concat_ws('|',
        coalesce(member_id, '~'), coalesce(billing_npi, '~'), coalesce(rendering_npi, '~'),
        coalesce(to_char(service_from_date, 'YYYY-MM-DD'), '~'),
        coalesce(place_of_service, '~'), coalesce(cpt_code, '~'), coalesce(modifier_1, '~'),
        coalesce(dx_code_1, '~'),
        coalesce(to_char(units, 'FM9999990.00'), '~'),
        coalesce(to_char(billed_amount, 'FM9999999990.00'), '~')))
$$;

CREATE OR REPLACE VIEW recon.v_expected_line_hashed AS
SELECT e.*,
       util.claim_line_hash(e.member_id, e.billing_npi, e.rendering_npi, e.service_from_date,
                            e.place_of_service, e.cpt_code, e.modifier_1, e.dx_code_1,
                            e.units, e.billed_amount) AS row_hash
FROM recon.v_expected_line e;

-- Actual warehouse rows (the "is" side), trimmed the same way (char(n) pads).
CREATE OR REPLACE VIEW recon.v_actual_line_hashed AS
SELECT f.claim_line_sk,
       f.load_batch_id, f.claim_id, f.line_no,
       f.member_id, rtrim(f.billing_npi) AS billing_npi, rtrim(f.rendering_npi) AS rendering_npi,
       f.service_from_date, rtrim(f.place_of_service) AS place_of_service,
       f.cpt_code, f.modifier_1, f.dx_code_1, f.units, f.billed_amount,
       util.claim_line_hash(f.member_id, rtrim(f.billing_npi), rtrim(f.rendering_npi),
                            f.service_from_date, rtrim(f.place_of_service), f.cpt_code,
                            f.modifier_1, f.dx_code_1, f.units, f.billed_amount) AS row_hash
FROM dw.fact_claim_line f;

-- -----------------------------------------------------------------------------
-- Staging -> warehouse load. Idempotent per batch (delete + insert).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dw.load_fact_claim_line(p_batch_id text)
LANGUAGE plpgsql AS
$$
DECLARE
    v_rows integer;
BEGIN
    DELETE FROM dw.fact_claim_line WHERE load_batch_id = p_batch_id;

    INSERT INTO dw.fact_claim_line (
        load_batch_id, claim_id, line_no, member_id, billing_npi, rendering_npi,
        service_from_date, place_of_service, cpt_code, modifier_1, dx_code_1,
        units, billed_amount)
    SELECT load_batch_id, claim_id, line_no, member_id, billing_npi, rendering_npi,
           service_from_date, place_of_service, cpt_code, modifier_1, dx_code_1,
           units, billed_amount
    FROM recon.v_expected_line
    WHERE load_batch_id = p_batch_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'dw.load_fact_claim_line: batch % loaded % rows', p_batch_id, v_rows;
END;
$$;
