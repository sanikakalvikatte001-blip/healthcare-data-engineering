-- =============================================================================
-- 01_stage_and_file_format.sql
-- External stage over the ADLS Gen2 landing container that ADF writes to.
-- A storage integration means no SAS tokens or keys live in Snowflake.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
CREATE STORAGE INTEGRATION IF NOT EXISTS ADLS_LANDING_INT
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'AZURE'
    ENABLED = TRUE
    AZURE_TENANT_ID = '<tenant-id>'
    STORAGE_ALLOWED_LOCATIONS = ('azure://<storageaccount>.blob.core.windows.net/landing/um/');
-- DESC STORAGE INTEGRATION ADLS_LANDING_INT;  -> consent URL + app name to grant
-- "Storage Blob Data Reader" on the container.
GRANT USAGE ON INTEGRATION ADLS_LANDING_INT TO ROLE LOADER;

USE ROLE LOADER;
USE SCHEMA RAW.UM;

CREATE FILE FORMAT IF NOT EXISTS FF_PARQUET
    TYPE = PARQUET
    USE_LOGICAL_TYPE = TRUE;          -- keep ADF's timestamp logical types

CREATE STAGE IF NOT EXISTS UM_LANDING_STAGE
    STORAGE_INTEGRATION = ADLS_LANDING_INT
    URL = 'azure://<storageaccount>.blob.core.windows.net/landing/um/'
    FILE_FORMAT = FF_PARQUET;
