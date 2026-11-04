-- =============================================================================
-- 02_raw_and_control_tables.sql
-- RAW tables are append-only copies of each extract plus load metadata.
-- Source columns are kept as text: RAW never rejects a file over a type
-- change; dbt staging does the casting.
-- =============================================================================
USE ROLE LOADER;

CREATE TABLE IF NOT EXISTS RAW.UM.PA_REQUEST (
    REQUEST_ID          VARCHAR,
    MEMBER_ID           VARCHAR,
    REQUESTING_NPI      VARCHAR,
    LINE_OF_BUSINESS    VARCHAR,
    SERVICE_CATEGORY    VARCHAR,
    PROCEDURE_CODE      VARCHAR,
    SUBMISSION_CHANNEL  VARCHAR,
    RECEIVED_AT         VARCHAR,
    PRIORITY            VARCHAR,
    MODIFIED_AT         VARCHAR,
    _FILE_NAME          VARCHAR,
    _LOADED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS RAW.UM.PA_STATUS_EVENT (
    EVENT_ID     VARCHAR,
    REQUEST_ID   VARCHAR,
    STATUS       VARCHAR,
    EVENT_AT     VARCHAR,
    REASON_CODE  VARCHAR,
    MODIFIED_AT  VARCHAR,
    _FILE_NAME   VARCHAR,
    _LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
);

-- One row per source table: the high-water mark of modified_at already landed.
CREATE TABLE IF NOT EXISTS RAW.CONTROL.WATERMARK (
    SOURCE_TABLE      VARCHAR NOT NULL PRIMARY KEY,
    WATERMARK_VALUE   TIMESTAMP_NTZ NOT NULL,
    LAST_RUN_ID       VARCHAR,
    UPDATED_AT        TIMESTAMP_NTZ
);

MERGE INTO RAW.CONTROL.WATERMARK t
USING (
    SELECT 'um.pa_request' AS SOURCE_TABLE UNION ALL SELECT 'um.pa_status_event'
) s
ON t.SOURCE_TABLE = s.SOURCE_TABLE
WHEN NOT MATCHED THEN
    INSERT (SOURCE_TABLE, WATERMARK_VALUE, UPDATED_AT)
    VALUES (s.SOURCE_TABLE, '1900-01-01'::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
