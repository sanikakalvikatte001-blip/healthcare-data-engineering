-- =============================================================================
-- 30_marts / dim_date
-- Grain: one row per calendar day covering the prior year + measurement year.
-- =============================================================================
CREATE OR REPLACE TABLE mart.dim_date AS
SELECT
    strftime(d, '%Y%m%d')::INT        AS date_key,
    d::DATE                           AS calendar_date,
    year(d)                           AS year,
    quarter(d)                        AS quarter,
    month(d)                          AS month,
    strftime(d, '%b')                 AS month_name,
    dayofweek(d) IN (0, 6)            AS is_weekend
FROM ref.cbp_params p,
     range(p.prior_year_start::TIMESTAMP, (p.my_end + 1)::TIMESTAMP, INTERVAL 1 DAY) t(d);
