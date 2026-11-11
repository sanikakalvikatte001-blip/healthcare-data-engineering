-- =============================================================================
-- 10_staging / reference: value sets, CPT II BP bands and measure parameters.
-- Codes are stored without dots and upper-cased so claims can be matched with
-- a plain equality join after the same normalization.
-- NOTE: value sets are a small illustrative subset, NOT the licensed NCQA
--       HEDIS value sets.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS ref;

CREATE OR REPLACE TABLE ref.value_set AS
SELECT value_set,
       code_system,
       upper(replace(trim(code), '.', '')) AS code,
       description
FROM read_csv('reference/value_sets.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ref.cpt2_bp_code AS
SELECT code, component, band, representative_value::INT AS representative_value
FROM read_csv('reference/cpt2_bp_codes.csv', header = true, all_varchar = true);

-- One typed row of parameters + every date window derived from the measurement
-- year, so no model hard-codes a date.
CREATE OR REPLACE TABLE ref.cbp_params AS
WITH p AS (
    PIVOT (SELECT param, value
           FROM read_csv('reference/measure_params.csv', header = true, all_varchar = true))
    ON param USING first(value)
)
SELECT
    measure_id,
    measurement_year::INT                                   AS my,
    make_date(measurement_year::INT, 1, 1)                  AS my_start,
    make_date(measurement_year::INT, 12, 31)                AS my_end,
    make_date(measurement_year::INT - 1, 1, 1)              AS prior_year_start,
    make_date(measurement_year::INT + htn_window_start_offset_years::INT, 1, 1) AS htn_window_start,
    strptime(measurement_year || '-' || htn_window_end_mmdd, '%Y-%m-%d')::DATE  AS htn_window_end,
    min_age::INT                      AS min_age,
    max_age::INT                      AS max_age,
    min_htn_visit_dates::INT          AS min_htn_visit_dates,
    ce_max_gaps::INT                  AS ce_max_gaps,
    ce_max_gap_days::INT              AS ce_max_gap_days,
    systolic_threshold::INT           AS systolic_threshold,
    diastolic_threshold::INT          AS diastolic_threshold,
    frailty_adv_illness_min_age::INT  AS frailty_adv_illness_min_age,
    frailty_only_min_age::INT         AS frailty_only_min_age
FROM p;
