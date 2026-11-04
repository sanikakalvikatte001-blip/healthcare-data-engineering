-- =============================================================================
-- marts.fct_claim_line — one row per current (non-void) professional claim line
--
-- The provider key is resolved POINT-IN-TIME on the date of service:
--   service_date BETWEEN effective_from AND effective_to
-- so a claim keeps the network status / specialty / TIN the provider had when
-- the service happened, no matter how the provider changes later.
--
-- provider_match_type documents how each line got its key:
--   POINT_IN_TIME  normal case
--   PRE_ROSTER     DOS earlier than the provider's first roster file (late
--                  credentialing) -> matched to the inferred PRE_ROSTER version
--   TERMED         DOS after the provider dropped off the roster
--   UNKNOWN_NPI    NPI never seen on any roster -> provider_sk = -1
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS marts;

CREATE OR REPLACE TABLE marts.fct_claim_line AS
SELECT
    c.claim_id,
    c.line_no,
    c.claim_freq_code,
    c.rendering_npi,                                     -- durable key
    coalesce(p.provider_sk, -1)                          AS provider_sk,
    CASE WHEN p.provider_sk IS NULL           THEN 'UNKNOWN_NPI'
         WHEN p.roster_status = 'PRE_ROSTER'  THEN 'PRE_ROSTER'
         WHEN p.roster_status = 'INACTIVE'    THEN 'TERMED'
         ELSE 'POINT_IN_TIME' END                        AS provider_match_type,
    coalesce(m.member_sk, -1)                            AS member_sk,
    strftime(c.service_date, '%Y%m%d')::INTEGER          AS service_date_sk,
    strftime(c.paid_date,    '%Y%m%d')::INTEGER          AS paid_date_sk,
    c.cpt_code,
    c.allowed_amt,
    c.paid_amt,
    c.version_count                                      -- 1 = never adjusted
FROM intermediate.int_claim_lines_current c
LEFT JOIN marts.dim_provider p
       ON p.npi = c.rendering_npi
      AND c.service_date BETWEEN p.effective_from AND p.effective_to
LEFT JOIN marts.dim_member m
       ON m.member_id = c.member_id;
