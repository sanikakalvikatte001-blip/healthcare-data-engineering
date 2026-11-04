-- =============================================================================
-- 03_copy_into_raw.sql
-- The statements ADF's Script activity runs after each Copy activity
-- (see adf/pipeline/pl_um_incremental_to_snowflake.json). Shown here with
-- one concrete run folder; ADF builds the path from the pipeline run.
--
-- COPY INTO keeps 64 days of load history per table, so a re-run of the
-- same file is skipped (no duplicates from pipeline retries). Rows that are
-- duplicated BETWEEN files (extract overlap) are handled in dbt staging.
-- =============================================================================
USE ROLE LOADER;
USE WAREHOUSE LOAD_WH;

COPY INTO RAW.UM.PA_REQUEST (
    REQUEST_ID, MEMBER_ID, REQUESTING_NPI, LINE_OF_BUSINESS, SERVICE_CATEGORY,
    PROCEDURE_CODE, SUBMISSION_CHANNEL, RECEIVED_AT, PRIORITY, MODIFIED_AT,
    _FILE_NAME, _LOADED_AT
)
FROM (
    SELECT
        $1:request_id::VARCHAR,
        $1:member_id::VARCHAR,
        $1:requesting_npi::VARCHAR,
        $1:line_of_business::VARCHAR,
        $1:service_category::VARCHAR,
        $1:procedure_code::VARCHAR,
        $1:submission_channel::VARCHAR,
        $1:received_at::VARCHAR,
        $1:priority::VARCHAR,
        $1:modified_at::VARCHAR,
        METADATA$FILENAME,
        CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM @RAW.UM.UM_LANDING_STAGE/pa_request/load_date=2026-11-01/
)
FILE_FORMAT = (FORMAT_NAME = 'RAW.UM.FF_PARQUET')
ON_ERROR = 'ABORT_STATEMENT';

COPY INTO RAW.UM.PA_STATUS_EVENT (
    EVENT_ID, REQUEST_ID, STATUS, EVENT_AT, REASON_CODE, MODIFIED_AT,
    _FILE_NAME, _LOADED_AT
)
FROM (
    SELECT
        $1:event_id::VARCHAR,
        $1:request_id::VARCHAR,
        $1:status::VARCHAR,
        $1:event_at::VARCHAR,
        $1:reason_code::VARCHAR,
        $1:modified_at::VARCHAR,
        METADATA$FILENAME,
        CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM @RAW.UM.UM_LANDING_STAGE/pa_status_event/load_date=2026-11-01/
)
FILE_FORMAT = (FORMAT_NAME = 'RAW.UM.FF_PARQUET')
ON_ERROR = 'ABORT_STATEMENT';

-- Advance the watermark only after COPY succeeded (same Script activity, so
-- a failed COPY leaves the old watermark and the next run re-extracts).
UPDATE RAW.CONTROL.WATERMARK
SET WATERMARK_VALUE = '2026-11-01 00:00:00'::TIMESTAMP_NTZ,
    LAST_RUN_ID     = '<adf-pipeline-run-id>',
    UPDATED_AT      = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
WHERE SOURCE_TABLE = 'um.pa_request';

-- Load audit: rows per file from Snowflake's own load history
SELECT TABLE_NAME, FILE_NAME, ROW_COUNT, ROW_PARSED, STATUS, LAST_LOAD_TIME
FROM TABLE(RAW.INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'RAW.UM.PA_STATUS_EVENT',
        START_TIME => DATEADD(DAY, -1, CURRENT_TIMESTAMP())))
ORDER BY LAST_LOAD_TIME DESC;
