-- Every provider has exactly one is_current version.
CREATE OR REPLACE VIEW tests.assert_dim_one_current_row_per_npi AS
SELECT npi, count(*) FILTER (WHERE is_current) AS current_rows
FROM marts.dim_provider
GROUP BY npi
HAVING count(*) FILTER (WHERE is_current) <> 1;
