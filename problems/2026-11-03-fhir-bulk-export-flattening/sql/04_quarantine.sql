-- =============================================================================
-- 04_quarantine.sql : everything that was NOT loaded, with a reason code.
-- One row per rejected line (malformed) or rejected resource. Superseded
-- versions are not errors and are counted in load_summary instead.
-- =============================================================================

CREATE OR REPLACE TEMP VIEW quarantine AS
-- Lines that are not valid JSON (truncated export, bad encoding ...)
SELECT 'Patient' AS resource_type, CAST(NULL AS STRING) AS resource_id,
       'MALFORMED_JSON' AS reason, source_file, left(_corrupt_record, 200) AS detail
FROM raw_patient WHERE _corrupt_record IS NOT NULL
UNION ALL
SELECT 'Encounter', NULL, 'MALFORMED_JSON', source_file, left(_corrupt_record, 200)
FROM raw_encounter WHERE _corrupt_record IS NOT NULL
UNION ALL
SELECT 'Observation', NULL, 'MALFORMED_JSON', source_file, left(_corrupt_record, 200)
FROM raw_observation WHERE _corrupt_record IS NOT NULL

UNION ALL
-- Encounters pointing at a Patient that is not in this export
SELECT 'Encounter', id, 'ORPHAN_PATIENT_REF', source_file, subject.reference
FROM encounter_resolved
WHERE NOT patient_found

UNION ALL
-- Observations rejected by the rules in 03_observation.sql
SELECT 'Observation', id, reject_reason, source_file,
       CASE reject_reason
           WHEN 'ORPHAN_PATIENT_REF' THEN subject.reference
           WHEN 'NO_LOINC_CODE'      THEN to_json(code.coding)
           ELSE status
       END
FROM observation_classified
WHERE reject_reason IS NOT NULL;
