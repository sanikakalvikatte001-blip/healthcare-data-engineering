-- =============================================================================
-- pipeline.sql - builds the whole CBP warehouse, layer by layer (DuckDB CLI).
--   duckdb -bail cbp.duckdb < pipeline.sql      (run from this folder)
-- Layers:  00_raw  ->  10_staging  ->  20_intermediate  ->  30_marts
-- =============================================================================
.bail on
.timer off

.print '[00_raw]           landing tables + synthetic feeds'
.read warehouse/00_raw/00_raw_tables.sql
.read warehouse/00_raw/01_scenario_members.sql
.read warehouse/00_raw/02_synthetic_population.sql

.print '[10_staging]       reference data, typing, parsing, dedup'
.read warehouse/10_staging/stg_reference.sql
.read warehouse/10_staging/stg_member_coverage.sql
.read warehouse/10_staging/stg_claim_codes.sql
.read warehouse/10_staging/stg_bp_vitals.sql

.print '[20_intermediate]  enrollment, HTN event, exclusions, BP logic'
.read warehouse/20_intermediate/int_enrollment_my.sql
.read warehouse/20_intermediate/int_htn_visits.sql
.read warehouse/20_intermediate/int_exclusion_event.sql
.read warehouse/20_intermediate/int_bp_candidates.sql
.read warehouse/20_intermediate/int_representative_bp.sql

.print '[30_marts]         dimensions, facts, measure rate, care gaps'
.read warehouse/30_marts/dim_member.sql
.read warehouse/30_marts/dim_date.sql
.read warehouse/30_marts/fct_bp_reading.sql
.read warehouse/30_marts/fct_cbp_member.sql
.read warehouse/30_marts/mart_cbp_rate.sql
.read warehouse/30_marts/mart_cbp_care_gap.sql

.print '[export]           output/*.csv'
COPY mart.cbp_rate                         TO 'output/cbp_rate.csv'         (HEADER);
COPY (SELECT outcome, count(*) AS members
      FROM mart.fct_cbp_member GROUP BY ALL ORDER BY members DESC)
                                           TO 'output/cbp_outcomes.csv'     (HEADER);
COPY mart.cbp_care_gap                     TO 'output/cbp_care_gaps.csv'    (HEADER);
COPY (SELECT reject_reason, count(*) AS rows FROM mart.dq_bp_reject GROUP BY ALL ORDER BY ALL)
                                           TO 'output/dq_bp_rejects.csv'    (HEADER);

.print ''
.print 'CBP rate by product line (MY2026)'
.mode box
SELECT product_line, eligible_population, required_exclusions, denominator,
       numerator, gap_uncontrolled, gap_no_reading, rate_pct
FROM mart.cbp_rate;
