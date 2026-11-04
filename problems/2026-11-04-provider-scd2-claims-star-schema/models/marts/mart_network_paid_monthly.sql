-- =============================================================================
-- marts.mart_network_paid_monthly
-- In-network vs out-of-network paid by service month, using the provider's
-- network status ON THE DATE OF SERVICE (the Type 2 join).
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS marts;

CREATE OR REPLACE TABLE marts.mart_network_paid_monthly AS
SELECT
    d.year_month                                    AS service_month,
    p.network_status                                AS network_status_at_dos,
    count(*)                                        AS claim_lines,
    count(DISTINCT f.claim_id)                      AS claims,
    sum(f.paid_amt)                                 AS paid_amt,
    round(100.0 * sum(f.paid_amt)
          / sum(sum(f.paid_amt)) OVER (PARTITION BY d.year_month), 1)
                                                    AS pct_of_month_paid
FROM marts.fct_claim_line f
JOIN marts.dim_date     d ON d.date_sk     = f.service_date_sk
JOIN marts.dim_provider p ON p.provider_sk = f.provider_sk
GROUP BY d.year_month, p.network_status
ORDER BY service_month, network_status_at_dos;
