-- =============================================================================
-- 00_raw: landing tables exactly as the source feeds deliver them.
-- Everything is VARCHAR on purpose: typing and cleanup happen in staging.
--   member_coverage : 834-style eligibility segments (dates as YYYYMMDD,
--                     blank term date = open-ended, segments may be resent)
--   claim_lines     : professional claim lines (dx codes with or without dots)
--   ehr_vitals      : EHR flowsheet blood-pressure rows (free text and/or
--                     discrete systolic/diastolic columns, any care setting)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS raw;

CREATE OR REPLACE TABLE raw.member_coverage (
    member_id        VARCHAR,
    birth_date       VARCHAR,
    gender           VARCHAR,
    product_line     VARCHAR,
    pcp_npi          VARCHAR,
    eff_date         VARCHAR,
    term_date        VARCHAR,
    source_file_date VARCHAR
);

CREATE OR REPLACE TABLE raw.claim_lines (
    claim_id   VARCHAR,
    line_no    VARCHAR,
    member_id  VARCHAR,
    dos        VARCHAR,
    pos_code   VARCHAR,
    proc_code  VARCHAR,
    dx1        VARCHAR,
    dx2        VARCHAR,
    dx3        VARCHAR
);

CREATE OR REPLACE TABLE raw.ehr_vitals (
    vital_id          VARCHAR,
    member_id         VARCHAR,
    encounter_setting VARCHAR,
    taken_at          VARCHAR,
    bp_text           VARCHAR,
    systolic          VARCHAR,
    diastolic         VARCHAR
);
