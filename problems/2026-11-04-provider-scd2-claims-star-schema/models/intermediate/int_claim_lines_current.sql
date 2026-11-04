-- =============================================================================
-- intermediate.int_claim_lines_current
-- Resolves claim versioning to the one line the warehouse should report:
--   * latest received version per (claim_id, line_no) wins
--   * if that latest version is a void (freq 8) the line is dropped
-- Superseded versions are counted so the build log can reconcile.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS intermediate;

CREATE OR REPLACE TABLE intermediate.int_claim_lines_current AS
WITH ranked AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY claim_id, line_no
            ORDER BY received_ts DESC, claim_freq_code DESC
        )                                         AS version_rank,
        count(*) OVER (PARTITION BY claim_id, line_no) AS version_count
    FROM staging.stg_claim_lines
)
SELECT
    claim_id, line_no, claim_freq_code, member_id, rendering_npi,
    service_date, paid_date, cpt_code, allowed_amt, paid_amt, received_ts,
    version_count
FROM ranked
WHERE version_rank = 1
  AND claim_freq_code <> '8';
