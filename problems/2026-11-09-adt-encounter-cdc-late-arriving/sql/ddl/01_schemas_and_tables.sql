-- =============================================================================
-- 01_schemas_and_tables.sql
-- Layered model for an incremental (CDC-style) load of HL7 v2 ADT events into
-- a current-state encounter table plus a Type 2 history.
--
--   landing.*  raw, append-only rows exactly as the interface engine delivered
--              them (already split from HL7 into columns: MSH/EVN/PID/PV1)
--   etl.*      batch control, per-row disposition, quarantine
--   core.*     de-duplicated event log, current encounter state, SCD2 history
-- =============================================================================

DROP SCHEMA IF EXISTS core    CASCADE;
DROP SCHEMA IF EXISTS etl     CASCADE;
DROP SCHEMA IF EXISTS landing CASCADE;

CREATE SCHEMA landing;
CREATE SCHEMA etl;
CREATE SCHEMA core;

-- -----------------------------------------------------------------------------
-- landing.adt_event : one row per delivered ADT message (append-only).
-- A message can be delivered more than once (interface-engine redelivery keeps
-- the MSH-10 control id; a manual "resend" from the EHR gets a new one).
-- -----------------------------------------------------------------------------
CREATE TABLE landing.adt_event (
    landing_id      bigserial    PRIMARY KEY,
    batch_id        date         NOT NULL,           -- daily drop the row arrived in
    source_system   text         NOT NULL,           -- MSH-3 sending application
    msg_control_id  text,                            -- MSH-10
    event_type      text,                            -- EVN-1 / MSH-9.2 (A01, A03 ...)
    event_ts        timestamp,                       -- EVN-2 recorded date/time
    received_ts     timestamp    NOT NULL,           -- when the engine received it
    facility        text,                            -- PV1-3.4 / MSH-4
    visit_number    text,                            -- PV1-19
    mrn             text,                            -- PID-3
    patient_class   text,                            -- PV1-2 (I / O / E)
    location        text,                            -- PV1-3 point of care
    attending_npi   text,                            -- PV1-7
    admit_ts        timestamp,                       -- PV1-44
    discharge_ts    timestamp                        -- PV1-45
);
CREATE INDEX ON landing.adt_event (batch_id);

-- -----------------------------------------------------------------------------
-- etl.batch_log : one row per load run of a batch (re-runs get run_no 2, 3...)
-- -----------------------------------------------------------------------------
CREATE TABLE etl.batch_log (
    batch_id              date        NOT NULL,
    run_no                int         NOT NULL,
    status                text        NOT NULL CHECK (status IN ('RUNNING','SUCCEEDED','FAILED')),
    started_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at           timestamptz,
    rows_landed           int,
    rows_quarantined      int,
    dup_control_id        int,
    dup_content           int,
    events_applied        int,
    late_events           int,
    encounters_inserted   int,
    encounters_updated    int,
    encounters_unchanged  int,
    error_message         text,
    PRIMARY KEY (batch_id, run_no)
);

-- -----------------------------------------------------------------------------
-- etl.event_disposition : every landing row gets exactly one outcome.
-- -----------------------------------------------------------------------------
CREATE TABLE etl.event_disposition (
    landing_id   bigint  PRIMARY KEY REFERENCES landing.adt_event (landing_id),
    batch_id     date    NOT NULL,
    disposition  text    NOT NULL CHECK (disposition IN
                   ('APPLIED','DUP_CONTROL_ID','DUP_CONTENT','QUARANTINED')),
    reason       text,
    event_id     bigint                       -- core.encounter_event row it maps to
);

-- -----------------------------------------------------------------------------
-- core.encounter_event : de-duplicated, immutable event log. This is the source
-- of truth the current state is re-derived from, in event-time order.
-- -----------------------------------------------------------------------------
CREATE TABLE core.encounter_event (
    event_id        bigserial   PRIMARY KEY,
    encounter_key   text        NOT NULL,        -- facility|visit_number
    source_system   text        NOT NULL,
    msg_control_id  text        NOT NULL,
    content_hash    text        NOT NULL,        -- md5 of business content
    event_type      text        NOT NULL,
    event_ts        timestamp   NOT NULL,
    received_ts     timestamp   NOT NULL,
    batch_id        date        NOT NULL,
    facility        text        NOT NULL,
    visit_number    text        NOT NULL,
    mrn             text,
    patient_class   text,
    location        text,
    attending_npi   text,
    admit_ts        timestamp,
    discharge_ts    timestamp,
    is_late         boolean     NOT NULL DEFAULT false,  -- older than state already published
    late_by         interval,                            -- how far behind it was
    CONSTRAINT uq_event_control UNIQUE (source_system, msg_control_id),
    CONSTRAINT uq_event_content UNIQUE (content_hash)
);
CREATE INDEX ON core.encounter_event (encounter_key, event_ts);

-- -----------------------------------------------------------------------------
-- core.encounter : current state, one row per encounter.
-- -----------------------------------------------------------------------------
CREATE TABLE core.encounter (
    encounter_key        text        PRIMARY KEY,
    facility             text        NOT NULL,
    visit_number         text        NOT NULL,
    mrn                  text,
    patient_class        text,
    status               text        NOT NULL CHECK (status IN
                           ('REGISTERED','ADMITTED','DISCHARGED','CANCELLED')),
    admit_ts             timestamp,
    discharge_ts         timestamp,
    location             text,
    attending_npi        text,
    last_event_ts        timestamp   NOT NULL,
    event_count          int         NOT NULL,
    state_hash           text        NOT NULL,
    first_loaded_batch   date        NOT NULL,
    last_changed_batch   date        NOT NULL
);

-- -----------------------------------------------------------------------------
-- core.encounter_history : SCD Type 2 over the published state, keyed on the
-- batch that published it. Lets you answer "what did the warehouse say about
-- this encounter on 2026-11-02?" — which is what downstream census reports saw.
-- -----------------------------------------------------------------------------
CREATE TABLE core.encounter_history (
    encounter_key    text      NOT NULL,
    version_no       int       NOT NULL,
    status           text      NOT NULL,
    patient_class    text,
    admit_ts         timestamp,
    discharge_ts     timestamp,
    location         text,
    attending_npi    text,
    state_hash       text      NOT NULL,
    valid_from_batch date      NOT NULL,
    valid_to_batch   date,                      -- NULL = current
    is_current       boolean   NOT NULL,
    change_cause     text      NOT NULL,        -- NEW / IN_ORDER / LATE_CORRECTION
    PRIMARY KEY (encounter_key, version_no)
);
CREATE UNIQUE INDEX uq_history_one_current
    ON core.encounter_history (encounter_key) WHERE is_current;
