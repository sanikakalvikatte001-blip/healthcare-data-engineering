-- =============================================================================
-- 00_schema.sql
-- Schemas and tables for the 837P claim-line load reconciliation framework.
--
--   src    : landing/staging area. 837P claim lines exactly as the X12 parser
--            wrote them -- every column is TEXT, nothing is cleaned yet.
--   dw     : warehouse. Typed fact table loaded from staging.
--   util   : small reusable helper functions (NPI Luhn check).
--   recon  : the reconciliation + data quality framework (rule catalog,
--            run log, control totals, per-rule results, exception table).
-- =============================================================================

DROP SCHEMA IF EXISTS recon CASCADE;
DROP SCHEMA IF EXISTS dw    CASCADE;
DROP SCHEMA IF EXISTS src   CASCADE;
DROP SCHEMA IF EXISTS util  CASCADE;

CREATE SCHEMA util;
CREATE SCHEMA src;
CREATE SCHEMA dw;
CREATE SCHEMA recon;

-- -----------------------------------------------------------------------------
-- Staging: one row per 837P service line (loop 2400), as landed from X12.
-- Source element references are shown in the comments.
-- -----------------------------------------------------------------------------
CREATE TABLE src.stg_837p_claim_line (
    load_batch_id        text NOT NULL,   -- ETL batch that landed the file
    file_id              text NOT NULL,   -- ISA13 interchange control number
    received_date        text NOT NULL,   -- CCYYMMDD, date the file arrived
    claim_id             text,            -- CLM01 patient control number
    line_no              text,            -- LX01 line counter
    member_id            text,            -- NM109 (2010BA subscriber id)
    billing_npi          text,            -- NM109 (2010AA billing provider)
    rendering_npi        text,            -- NM109 (2420A rendering provider)
    service_from_date    text,            -- DTP03 (DTP*472), CCYYMMDD
    place_of_service     text,            -- SV105 or CLM05-1
    cpt_code             text,            -- SV101-2
    modifier_1           text,            -- SV101-3
    dx_code_1            text,            -- HI01-2 pointed to by SV107
    units                text,            -- SV104
    billed_amount        text             -- SV102
);

-- -----------------------------------------------------------------------------
-- Warehouse fact. No unique constraint on (claim_id, line_no) on purpose:
-- many real warehouses do not enforce business keys on large facts, which is
-- exactly how duplicate loads slip in. Reconciliation has to catch them.
-- -----------------------------------------------------------------------------
CREATE TABLE dw.fact_claim_line (
    claim_line_sk        bigserial PRIMARY KEY,
    load_batch_id        text          NOT NULL,
    claim_id             text          NOT NULL,
    line_no              integer       NOT NULL,
    member_id            text,
    billing_npi          char(10),
    rendering_npi        char(10),
    service_from_date    date,
    place_of_service     char(2),
    cpt_code             varchar(5),
    modifier_1           varchar(2),
    dx_code_1            varchar(7),
    units                numeric(9,2),
    billed_amount        numeric(12,2),
    loaded_at            timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX ix_fact_claim_line_key ON dw.fact_claim_line (load_batch_id, claim_id, line_no);

-- -----------------------------------------------------------------------------
-- Reconciliation framework tables
-- -----------------------------------------------------------------------------

-- Rule catalog: every check is a row. check_sql must return
-- (claim_id text, line_no int, detail jsonb). {batch_id} is replaced at run time.
CREATE TABLE recon.rule_catalog (
    rule_code        text PRIMARY KEY,
    rule_group       text    NOT NULL CHECK (rule_group IN ('RECON', 'SOURCE_DQ')),
    severity         text    NOT NULL CHECK (severity IN ('CRITICAL', 'WARN')),
    max_exceptions   integer NOT NULL DEFAULT 0,  -- tolerance before the rule fails
    description      text    NOT NULL,
    check_sql        text    NOT NULL,
    is_active        boolean NOT NULL DEFAULT true
);

CREATE TABLE recon.run_log (
    run_id        bigserial PRIMARY KEY,
    load_batch_id text        NOT NULL,
    started_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at   timestamptz,
    run_status    text        -- PASS / WARN / FAIL
);

-- Control totals: source vs target at batch grain and service-month grain.
CREATE TABLE recon.control_total (
    run_id        bigint  NOT NULL REFERENCES recon.run_log,
    grain         text    NOT NULL,      -- 'BATCH' or 'SERVICE_MONTH'
    grain_value   text    NOT NULL,      -- batch id or YYYY-MM
    metric        text    NOT NULL,      -- line_count, claim_count, billed_amount, units
    source_value  numeric NOT NULL,
    target_value  numeric NOT NULL,
    variance      numeric GENERATED ALWAYS AS (target_value - source_value) STORED,
    PRIMARY KEY (run_id, grain, grain_value, metric)
);

-- One row per rule per run.
CREATE TABLE recon.rule_result (
    run_id           bigint  NOT NULL REFERENCES recon.run_log,
    rule_code        text    NOT NULL REFERENCES recon.rule_catalog,
    severity         text    NOT NULL,
    exception_count  integer NOT NULL,
    max_exceptions   integer NOT NULL,
    rule_status      text    NOT NULL,  -- PASS / WARN / FAIL
    PRIMARY KEY (run_id, rule_code)
);

-- Row-level exceptions that a data steward can work.
CREATE TABLE recon.exception (
    exception_id  bigserial PRIMARY KEY,
    run_id        bigint NOT NULL REFERENCES recon.run_log,
    rule_code     text   NOT NULL REFERENCES recon.rule_catalog,
    severity      text   NOT NULL,
    claim_id      text,
    line_no       integer,
    detail        jsonb
);
CREATE INDEX ix_exception_run_rule ON recon.exception (run_id, rule_code);
