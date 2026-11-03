-- =============================================================================
-- 05_load_summary.sql : line-level reconciliation per resource type.
-- Every input NDJSON line must be accounted for exactly once:
--     input_lines = malformed_lines + superseded_lines + quarantined + loaded_resources
-- `balanced` is the check a scheduler/alert would watch.
-- =============================================================================

CREATE OR REPLACE TEMP VIEW load_summary AS
WITH raw_counts AS (
    SELECT 'Patient' AS resource_type,
           COUNT(*) AS input_lines,
           COUNT(_corrupt_record) AS malformed_lines,
           COUNT(DISTINCT CASE WHEN _corrupt_record IS NULL THEN id END) AS distinct_resources
    FROM raw_patient
    UNION ALL
    SELECT 'Encounter', COUNT(*), COUNT(_corrupt_record),
           COUNT(DISTINCT CASE WHEN _corrupt_record IS NULL THEN id END)
    FROM raw_encounter
    UNION ALL
    SELECT 'Observation', COUNT(*), COUNT(_corrupt_record),
           COUNT(DISTINCT CASE WHEN _corrupt_record IS NULL THEN id END)
    FROM raw_observation
),
quarantined AS (
    SELECT resource_type, COUNT(*) AS quarantined
    FROM quarantine
    WHERE resource_id IS NOT NULL            -- malformed lines are counted separately
    GROUP BY resource_type
),
loaded AS (
    SELECT 'Patient' AS resource_type, COUNT(*) AS loaded_resources, COUNT(*) AS flat_rows FROM patient_flat
    UNION ALL
    SELECT 'Encounter', COUNT(*), COUNT(*) FROM encounter_flat
    UNION ALL
    SELECT 'Observation', COUNT(DISTINCT observation_id), COUNT(*) FROM observation_flat
)
SELECT
    r.resource_type,
    r.input_lines,
    r.malformed_lines,
    r.input_lines - r.malformed_lines - r.distinct_resources AS superseded_lines,
    COALESCE(q.quarantined, 0)                              AS quarantined,
    l.loaded_resources,
    l.flat_rows,
    r.input_lines = r.malformed_lines
                  + (r.input_lines - r.malformed_lines - r.distinct_resources)
                  + COALESCE(q.quarantined, 0)
                  + l.loaded_resources                      AS balanced
FROM raw_counts r
LEFT JOIN quarantined q ON q.resource_type = r.resource_type
LEFT JOIN loaded      l ON l.resource_type = r.resource_type
ORDER BY CASE r.resource_type WHEN 'Patient' THEN 1 WHEN 'Encounter' THEN 2 ELSE 3 END;
