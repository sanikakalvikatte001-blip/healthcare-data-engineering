-- =============================================================================
-- 30_marts / mart_cbp_rate
-- Grain: one row per product line plus an 'ALL' roll-up (GROUPING SETS).
-- rate = numerator / denominator (exclusions are removed from the denominator).
-- =============================================================================
CREATE OR REPLACE TABLE mart.cbp_rate AS
SELECT
    measure_id,
    measurement_year,
    coalesce(product_line, 'ALL')                              AS product_line,
    count(*) FILTER (WHERE in_eligible_population)             AS eligible_population,
    count(*) FILTER (WHERE in_eligible_population
                       AND exclusion_reason IS NOT NULL)       AS required_exclusions,
    count(*) FILTER (WHERE in_denominator)                     AS denominator,
    count(*) FILTER (WHERE in_numerator)                       AS numerator,
    count(*) FILTER (WHERE outcome = 'GAP_UNCONTROLLED')       AS gap_uncontrolled,
    count(*) FILTER (WHERE outcome = 'GAP_NO_READING')         AS gap_no_reading,
    round(100.0 * numerator / nullif(denominator, 0), 2)       AS rate_pct
FROM mart.fct_cbp_member
GROUP BY GROUPING SETS ((measure_id, measurement_year, product_line),
                        (measure_id, measurement_year))
ORDER BY product_line = 'ALL', product_line;
