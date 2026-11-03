-- =============================================================================
-- 02_encounter.sql : Encounter -> encounter_flat (one row per encounter)
-- Input : raw_encounter, patient_flat
-- =============================================================================

CREATE OR REPLACE TEMP VIEW encounter_latest AS
SELECT *
FROM (
    SELECT e.*,
           ROW_NUMBER() OVER (
               PARTITION BY id
               ORDER BY TRY_CAST(meta.versionId AS INT) DESC,
                        TRY_CAST(meta.lastUpdated AS TIMESTAMP) DESC,
                        source_file DESC
           ) AS version_rank
    FROM raw_encounter e
    WHERE _corrupt_record IS NULL
      AND resourceType = 'Encounter'
      AND id IS NOT NULL
) ranked
WHERE version_rank = 1;


-- References may be relative ("Patient/123") or absolute
-- ("https://server/R4/Patient/123"). Take the id after the last "Patient/".
CREATE OR REPLACE TEMP VIEW encounter_resolved AS
WITH refs AS (
    SELECT e.*,
           NULLIF(regexp_extract(e.subject.reference, '(?:^|/)Patient/([^/]+)$', 1), '') AS patient_ref_id
    FROM encounter_latest e
)
SELECT r.*,
       p.patient_id IS NOT NULL AS patient_found
FROM refs r
LEFT JOIN patient_flat p
       ON p.patient_id = r.patient_ref_id;


-- Only encounters whose patient is in the export are loaded; the rest go to quarantine.
CREATE OR REPLACE TEMP VIEW encounter_flat AS
WITH typed AS (
    SELECT r.*,
           try_element_at(filter(try_element_at(r.`type`, 1).coding,
                                 c -> c.system = 'http://snomed.info/sct'), 1) AS type_sct,
           TRY_CAST(r.period.start AS TIMESTAMP) AS start_ts,
           TRY_CAST(r.period.`end` AS TIMESTAMP) AS end_ts
    FROM encounter_resolved r
    WHERE r.patient_found
)
SELECT
    id                                              AS encounter_id,
    patient_ref_id                                  AS patient_id,
    status,
    `class`.code                                    AS class_code,     -- AMB / EMER / IMP
    type_sct.code                                   AS type_snomed_code,
    type_sct.display                                AS type_display,
    start_ts                                        AS period_start,
    end_ts                                          AS period_end,     -- NULL while in-progress
    ROUND((unix_timestamp(end_ts) - unix_timestamp(start_ts)) / 3600.0, 2) AS length_of_stay_hours,
    TRY_CAST(meta.versionId AS INT)                 AS version_id,
    TRY_CAST(meta.lastUpdated AS TIMESTAMP)         AS last_updated,
    source_file
FROM typed;
