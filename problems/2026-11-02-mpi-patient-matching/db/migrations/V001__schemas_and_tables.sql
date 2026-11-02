-- =============================================================================
-- V001  Schemas, extensions and tables for the Master Patient Index (MPI)
--
--   stg  : raw registration messages exactly as each source sends them
--   mpi  : normalized source records, enterprise IDs, scores, review queue
--   util : pure helper functions (normalization)
--
-- Re-runnable: drops and recreates the three schemas.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;   -- levenshtein, soundex, dmetaphone
CREATE EXTENSION IF NOT EXISTS pg_trgm;         -- trigram similarity for addresses

DROP SCHEMA IF EXISTS mpi  CASCADE;
DROP SCHEMA IF EXISTS stg  CASCADE;
DROP SCHEMA IF EXISTS util CASCADE;
CREATE SCHEMA stg;
CREATE SCHEMA mpi;
CREATE SCHEMA util;

-- -----------------------------------------------------------------------------
-- Staging: one row per registration/ADT message. Everything is text because
-- every source formats dates, phones, SSNs and sex codes differently.
-- -----------------------------------------------------------------------------
CREATE TABLE stg.patient_registration (
    load_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id           text        NOT NULL,
    source_system      text        NOT NULL,        -- EHR_EPIC, LAB_LIS, CLAIMS_PAYER
    source_patient_id  text        NOT NULL,        -- the source's MRN / member ID
    first_name         text,
    middle_name        text,
    last_name          text,
    birth_date_raw     text,
    sex_raw            text,
    ssn_raw            text,
    phone_raw          text,
    address_line       text,
    zip_raw            text,
    received_at        timestamptz NOT NULL
);
CREATE INDEX ON stg.patient_registration (batch_id);

-- The made-up people behind the synthetic feed (filled by db/seed).
CREATE TABLE stg.synthetic_person (
    person_id     int PRIMARY KEY,
    sex           char(1) NOT NULL,
    first_name    text NOT NULL,
    last_name     text NOT NULL,
    birth_date    date NOT NULL,
    ssn           text NOT NULL,
    phone         text NOT NULL,
    address_line  text NOT NULL,
    zip           text NOT NULL,
    family_role   text NOT NULL       -- independent / twin_of_N / junior_of_N
);

-- Ground truth for the SYNTHETIC data only (which made-up person each source
-- record really belongs to). Used by the quality report and tests, never by
-- the matcher itself.
CREATE TABLE stg.synthetic_truth (
    source_system      text NOT NULL,
    source_patient_id  text NOT NULL,
    true_person_id     int  NOT NULL,
    scenario           text NOT NULL,                -- clean, nickname, typo, twin, ...
    PRIMARY KEY (source_system, source_patient_id)
);

-- -----------------------------------------------------------------------------
-- Enterprise patient: the golden identifier handed to downstream systems.
-- Merged IDs are never deleted; they point at their survivor.
-- -----------------------------------------------------------------------------
CREATE TABLE mpi.enterprise_patient (
    enterprise_id   bigint GENERATED ALWAYS AS IDENTITY (START WITH 100001) PRIMARY KEY,
    status          text   NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'MERGED')),
    merged_into     bigint REFERENCES mpi.enterprise_patient,
    created_batch   text   NOT NULL,
    merged_batch    text,
    CHECK ((status = 'MERGED') = (merged_into IS NOT NULL))
);

-- Normalized, current-state copy of each source record (cross-reference).
CREATE TABLE mpi.source_patient (
    source_system      text NOT NULL,
    source_patient_id  text NOT NULL,
    enterprise_id      bigint REFERENCES mpi.enterprise_patient,
    first_name         text NOT NULL,
    first_name_canon   text NOT NULL,                -- nickname resolved (BOB -> ROBERT)
    last_name          text NOT NULL,
    birth_date         date NOT NULL,
    sex                char(1),                      -- M / F / NULL
    ssn                char(9),                      -- NULL when missing or a placeholder
    phone              char(10),
    address_norm       text,
    zip5               char(5),
    record_hash        text NOT NULL,                -- change detection on resends
    first_batch        text NOT NULL,
    last_batch         text NOT NULL,
    needs_matching     boolean NOT NULL DEFAULT true,
    PRIMARY KEY (source_system, source_patient_id)
);
CREATE INDEX ON mpi.source_patient (enterprise_id);

-- Blocking keys: only records sharing at least one key are ever compared.
CREATE TABLE mpi.block_key (
    source_system      text NOT NULL,
    source_patient_id  text NOT NULL,
    block_key          text NOT NULL,
    PRIMARY KEY (source_system, source_patient_id, block_key),
    FOREIGN KEY (source_system, source_patient_id) REFERENCES mpi.source_patient ON DELETE CASCADE
);
CREATE INDEX ON mpi.block_key (block_key);

-- Rows that cannot be matched at all (no name, unparseable DOB).
CREATE TABLE mpi.registration_reject (
    load_id     bigint PRIMARY KEY,
    batch_id    text NOT NULL,
    reason      text NOT NULL
);

-- Every scored candidate pair, with the per-field outcome for explainability.
CREATE TABLE mpi.match_score (
    batch_id     text NOT NULL,
    a_system     text NOT NULL,
    a_id         text NOT NULL,
    b_system     text NOT NULL,
    b_id         text NOT NULL,
    last_cmp     text, first_cmp text, dob_cmp text, ssn_cmp text,
    sex_cmp      text, phone_cmp text, zip_cmp text, addr_cmp text,
    total_weight numeric(6,2) NOT NULL,
    decision     text NOT NULL CHECK (decision IN ('AUTO_LINK', 'REVIEW', 'NON_MATCH')),
    PRIMARY KEY (batch_id, a_system, a_id, b_system, b_id)
);

-- Work queue for HIM / data stewards.
CREATE TABLE mpi.review_queue (
    review_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id     text NOT NULL,
    a_system     text NOT NULL, a_id text NOT NULL,
    b_system     text NOT NULL, b_id text NOT NULL,
    total_weight numeric(6,2) NOT NULL,
    reason       text NOT NULL,       -- SCORE_IN_REVIEW_BAND / SAME_SOURCE_DUPLICATE / MERGE_BLOCKED_SAME_SOURCE
    status       text NOT NULL DEFAULT 'OPEN',
    UNIQUE (a_system, a_id, b_system, b_id)
);

-- Append-only audit of every identity decision.
CREATE TABLE mpi.link_audit (
    audit_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id          text NOT NULL,
    event             text NOT NULL CHECK (event IN ('NEW_ENTERPRISE_ID', 'LINK', 'MERGE')),
    source_system     text,
    source_patient_id text,
    enterprise_id     bigint NOT NULL,
    other_enterprise_id bigint,
    total_weight      numeric(6,2),
    logged_at         timestamptz NOT NULL DEFAULT clock_timestamp()
);
