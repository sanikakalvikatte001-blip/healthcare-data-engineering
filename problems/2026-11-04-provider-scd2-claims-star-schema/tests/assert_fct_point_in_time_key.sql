-- Each fact row's provider version was valid on the date of service and
-- belongs to the same NPI (unknown member excepted).
CREATE OR REPLACE VIEW tests.assert_fct_point_in_time_key AS
SELECT f.claim_id, f.line_no, f.rendering_npi, p.npi, d.calendar_date,
       p.effective_from, p.effective_to
FROM marts.fct_claim_line f
JOIN marts.dim_date d     ON d.date_sk = f.service_date_sk
JOIN marts.dim_provider p ON p.provider_sk = f.provider_sk
WHERE f.provider_sk <> -1
  AND (p.npi <> f.rendering_npi
       OR d.calendar_date NOT BETWEEN p.effective_from AND p.effective_to);
