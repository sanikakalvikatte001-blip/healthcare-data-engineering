-- Two consecutive versions must differ in at least one Type 2 attribute,
-- otherwise cosmetic noise or duplicate files leaked into history.
CREATE OR REPLACE VIEW tests.assert_dim_no_redundant_versions AS
WITH ordered AS (
    SELECT npi, effective_from, taxonomy_code, network_status, group_tin, roster_status,
           lag(taxonomy_code)  OVER w AS prev_tax,
           lag(network_status) OVER w AS prev_net,
           lag(group_tin)      OVER w AS prev_tin,
           lag(roster_status)  OVER w AS prev_status
    FROM marts.dim_provider
    WINDOW w AS (PARTITION BY npi ORDER BY effective_from)
)
SELECT * FROM ordered
WHERE prev_tax IS NOT NULL
  AND taxonomy_code = prev_tax AND network_status = prev_net
  AND group_tin = prev_tin     AND roster_status  = prev_status;
