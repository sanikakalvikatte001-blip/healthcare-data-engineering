-- =============================================================================
-- build.sql — runs every layer in dependency order (DuckDB CLI)
--   duckdb -bail warehouse.duckdb < build.sql
-- =============================================================================
.bail on
.print '>> seeds (synthetic raw sources)'
.read seeds/generate_synthetic_sources.sql

.print '>> staging'
.read models/staging/stg_provider_roster.sql
.read models/staging/stg_claim_lines.sql
.read models/staging/stg_members.sql

.print '>> intermediate'
.read models/intermediate/int_provider_monthly_state.sql
.read models/intermediate/int_provider_versions.sql
.read models/intermediate/int_claim_lines_current.sql

.print '>> marts'
.read models/marts/dim_date.sql
.read models/marts/dim_member.sql
.read models/marts/dim_provider.sql
.read models/marts/fct_claim_line.sql
.read models/marts/mart_network_paid_monthly.sql
.read models/marts/mart_attribution_drift.sql

.print '>> export marts to output/'
COPY marts.dim_provider              TO 'output/dim_provider.csv'              (HEADER);
COPY marts.mart_network_paid_monthly TO 'output/mart_network_paid_monthly.csv' (HEADER);
COPY marts.mart_attribution_drift    TO 'output/mart_attribution_drift.csv'    (HEADER);
.print '>> build complete'
