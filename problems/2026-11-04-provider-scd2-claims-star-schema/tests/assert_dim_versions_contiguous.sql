-- Versions of one provider never overlap and never leave a hole:
-- next.effective_from must be exactly this.effective_to + 1 day.
CREATE OR REPLACE VIEW tests.assert_dim_versions_contiguous AS
WITH ordered AS (
    SELECT npi, effective_from, effective_to,
           lead(effective_from) OVER (PARTITION BY npi ORDER BY effective_from) AS next_from
    FROM marts.dim_provider
)
SELECT * FROM ordered
WHERE effective_from > effective_to
   OR (next_from IS NOT NULL AND next_from <> effective_to + INTERVAL 1 DAY)
   OR (next_from IS NULL AND effective_to <> DATE '9999-12-31');
