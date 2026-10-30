-- =============================================================================
-- 03_load_with_defects.sql
-- Runs the real staging -> warehouse load, then simulates the load bugs we see
-- in production so the reconciliation has something to find:
--
--   missing lines      7   (rows rejected by a downstream filter, never logged)
--   duplicate lines    4   (job restarted mid-batch without delete/insert)
--   extra lines        3   (rows from another file stamped with this batch id)
--   value mismatches  13 lines:
--       billed_amount  5   (allowed amount mapped into billed by mistake)
--       service date   3   (timestamp -> date conversion in UTC, off by 1 day)
--       modifier       4   (modifier dropped by a fixed-width mapping)
--       billed + date  1   (two columns wrong on the same line)
-- =============================================================================

CALL dw.load_fact_claim_line('B20261030');

-- Missing in target.
DELETE FROM dw.fact_claim_line
WHERE claim_id BETWEEN 'CLM0000301' AND 'CLM0000307' AND line_no = 1;

-- Duplicated in target.
INSERT INTO dw.fact_claim_line (
    load_batch_id, claim_id, line_no, member_id, billing_npi, rendering_npi,
    service_from_date, place_of_service, cpt_code, modifier_1, dx_code_1, units, billed_amount)
SELECT load_batch_id, claim_id, line_no, member_id, billing_npi, rendering_npi,
       service_from_date, place_of_service, cpt_code, modifier_1, dx_code_1, units, billed_amount
FROM dw.fact_claim_line
WHERE claim_id BETWEEN 'CLM0000311' AND 'CLM0000314' AND line_no = 1;

-- Extra in target (no matching source line).
INSERT INTO dw.fact_claim_line (
    load_batch_id, claim_id, line_no, member_id, billing_npi, rendering_npi,
    service_from_date, place_of_service, cpt_code, modifier_1, dx_code_1, units, billed_amount)
VALUES
    ('B20261030', 'CLM9000001', 1, 'M000777', '1000079198', '1000079198', '2026-06-30', '11', '99213', NULL, 'I10',  1, 101.25),
    ('B20261030', 'CLM9000001', 2, 'M000777', '1000079198', '1000079198', '2026-06-30', '11', '36415', NULL, 'I10',  1,  12.40),
    ('B20261030', 'CLM9000002', 1, 'M000778', '1000079198', '1000079198', '2026-06-29', '11', '99214', '25', 'E119', 1, 150.00);

-- Billed amount loaded from the wrong element (90% "allowed").
UPDATE dw.fact_claim_line
SET billed_amount = round(billed_amount * 0.90, 2)
WHERE claim_id BETWEEN 'CLM0000321' AND 'CLM0000325' AND line_no = 1;

-- Service date shifted back one day.
UPDATE dw.fact_claim_line
SET service_from_date = service_from_date - 1
WHERE claim_id BETWEEN 'CLM0000331' AND 'CLM0000333' AND line_no = 1;

-- Modifier dropped (source has '25' on these lines).
UPDATE dw.fact_claim_line
SET modifier_1 = NULL
WHERE claim_id BETWEEN 'CLM0000341' AND 'CLM0000344' AND line_no = 1;

-- Two columns wrong on one line.
UPDATE dw.fact_claim_line
SET billed_amount = billed_amount + 10, service_from_date = service_from_date + 1
WHERE claim_id = 'CLM0000351' AND line_no = 1;
