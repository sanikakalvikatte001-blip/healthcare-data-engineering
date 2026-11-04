-- =============================================================================
-- marts.mart_attribution_drift
-- Quantifies what goes wrong if a report joins claims to the CURRENT provider
-- row (a common Type 1 shortcut) instead of the row valid on the DOS.
-- One row per kind of drift, with lines and paid dollars affected.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS marts;

CREATE OR REPLACE TABLE marts.mart_attribution_drift AS
WITH compared AS (
    SELECT
        f.claim_id, f.line_no, f.paid_amt,
        hist.network_status AS network_at_dos,
        cur.network_status  AS network_current,
        hist.specialty_desc AS specialty_at_dos,
        cur.specialty_desc  AS specialty_current,
        hist.group_tin      AS tin_at_dos,
        cur.group_tin       AS tin_current
    FROM marts.fct_claim_line f
    JOIN marts.dim_provider hist ON hist.provider_sk = f.provider_sk
    JOIN marts.dim_provider cur  ON cur.npi = f.rendering_npi AND cur.is_current
    WHERE f.provider_sk <> -1
),
drift AS (
    SELECT 'network_status' AS attribute,
           network_at_dos || ' -> ' || network_current AS change, paid_amt
    FROM compared WHERE network_at_dos <> network_current
    UNION ALL
    SELECT 'specialty', specialty_at_dos || ' -> ' || specialty_current, paid_amt
    FROM compared WHERE specialty_at_dos <> specialty_current
    UNION ALL
    SELECT 'group_tin', tin_at_dos || ' -> ' || tin_current, paid_amt
    FROM compared WHERE tin_at_dos <> tin_current
)
SELECT
    attribute,
    change                    AS at_dos_vs_current,
    count(*)                  AS claim_lines,
    sum(paid_amt)             AS paid_amt
FROM drift
GROUP BY ALL
ORDER BY attribute, paid_amt DESC;
