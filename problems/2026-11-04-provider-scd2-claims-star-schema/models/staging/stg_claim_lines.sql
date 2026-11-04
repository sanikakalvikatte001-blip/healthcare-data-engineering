-- =============================================================================
-- staging.stg_claim_lines
-- Typed, trimmed claim lines with exact duplicate re-sends removed.
-- Replacement (7) and void (8) versions are kept here; they are resolved in
-- the intermediate layer.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS staging;

CREATE OR REPLACE VIEW staging.stg_claim_lines AS
SELECT DISTINCT                       -- clearinghouse retries are byte-identical
    trim(claim_id)                    AS claim_id,
    line_no::INTEGER                  AS line_no,
    trim(claim_freq_code)             AS claim_freq_code,
    trim(member_id)                   AS member_id,
    trim(rendering_npi)               AS rendering_npi,
    service_date::DATE                AS service_date,
    paid_date::DATE                   AS paid_date,
    upper(trim(cpt_code))             AS cpt_code,
    allowed_amt::DECIMAL(12, 2)       AS allowed_amt,
    paid_amt::DECIMAL(12, 2)          AS paid_amt,
    received_ts::TIMESTAMP            AS received_ts
FROM raw.claim_line;
