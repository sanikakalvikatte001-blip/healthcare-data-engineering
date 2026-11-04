-- =============================================================================
-- marts.dim_date — calendar dimension, smart key YYYYMMDD
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS marts;

CREATE OR REPLACE TABLE marts.dim_date AS
SELECT
    strftime(d, '%Y%m%d')::INTEGER         AS date_sk,
    d::DATE                                AS calendar_date,
    year(d)                                AS year,
    quarter(d)                             AS quarter,
    month(d)                               AS month,
    strftime(d, '%Y-%m')                   AS year_month,
    dayofweek(d)                           AS day_of_week,     -- 0 = Sunday
    dayofweek(d) IN (0, 6)                 AS is_weekend
FROM range(DATE '2024-01-01', DATE '2027-01-01', INTERVAL 1 DAY) t(d);
