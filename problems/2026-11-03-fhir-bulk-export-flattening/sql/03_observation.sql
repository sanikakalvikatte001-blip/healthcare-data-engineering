-- =============================================================================
-- 03_observation.sql : Observation -> observation_flat
-- Grain : one row per measured value. A blood-pressure panel (85354-9) carries
--         systolic and diastolic as components, so it becomes 2 rows that share
--         observation_id and differ by component_seq.
-- Input : raw_observation, patient_flat, encounter_flat
-- =============================================================================

CREATE OR REPLACE TEMP VIEW observation_latest AS
SELECT *
FROM (
    SELECT o.*,
           ROW_NUMBER() OVER (
               PARTITION BY id
               ORDER BY TRY_CAST(meta.versionId AS INT) DESC,
                        TRY_CAST(meta.lastUpdated AS TIMESTAMP) DESC,
                        source_file DESC
           ) AS version_rank
    FROM raw_observation o
    WHERE _corrupt_record IS NULL
      AND resourceType = 'Observation'
      AND id IS NOT NULL
) ranked
WHERE version_rank = 1;


-- Resolve references, pick the LOINC coding, and give each resource ONE reject
-- reason (first rule that fails wins).
CREATE OR REPLACE TEMP VIEW observation_classified AS
WITH r AS (
    SELECT o.*,
           NULLIF(regexp_extract(o.subject.reference,   '(?:^|/)Patient/([^/]+)$',   1), '') AS patient_ref_id,
           NULLIF(regexp_extract(o.encounter.reference, '(?:^|/)Encounter/([^/]+)$', 1), '') AS encounter_ref_id,
           -- Lab interfaces often send the local code first and LOINC second:
           -- select by code system, never by position.
           try_element_at(filter(o.code.coding, c -> c.system = 'http://loinc.org'), 1)       AS loinc
    FROM observation_latest o
)
SELECT r.*,
       CASE
           WHEN r.status = 'entered-in-error' THEN 'ENTERED_IN_ERROR'
           WHEN p.patient_id IS NULL          THEN 'ORPHAN_PATIENT_REF'
           WHEN r.loinc IS NULL               THEN 'NO_LOINC_CODE'
       END AS reject_reason
FROM r
LEFT JOIN patient_flat p
       ON p.patient_id = r.patient_ref_id;


CREATE OR REPLACE TEMP VIEW observation_flat AS
WITH exploded AS (
    -- OUTER keeps observations that have no components (one row with comp = NULL).
    SELECT o.*, comp_pos, comp
    FROM observation_classified o
    LATERAL VIEW OUTER posexplode(o.component) c AS comp_pos, comp
    WHERE o.reject_reason IS NULL
),
measured AS (
    SELECT x.*,
           -- For a component row, code and value[x] come from the component.
           IF(comp IS NULL, loinc,
              try_element_at(filter(comp.code.coding, c -> c.system = 'http://loinc.org'), 1)) AS m_code,
           IF(comp IS NULL, valueQuantity,        comp.valueQuantity)        AS v_qty,
           IF(comp IS NULL, valueCodeableConcept, comp.valueCodeableConcept) AS v_cc,
           IF(comp IS NULL, valueString,          comp.valueString)          AS v_str
    FROM exploded x
)
SELECT
    m.id                                                    AS observation_id,
    IF(m.comp IS NULL, 0, m.comp_pos + 1)                   AS component_seq,
    m.patient_ref_id                                        AS patient_id,
    e.encounter_id                                          AS encounter_id,   -- NULL if not in export
    m.status,
    try_element_at(try_element_at(m.category, 1).coding, 1).code AS category,
    m.m_code.code                                           AS loinc_code,
    m.m_code.display                                        AS loinc_display,
    IF(m.comp IS NULL, NULL, m.loinc.code)                  AS panel_loinc_code,
    CASE
        WHEN m.v_qty IS NOT NULL            THEN 'Quantity'
        WHEN m.v_cc  IS NOT NULL            THEN 'CodeableConcept'
        WHEN m.v_str IS NOT NULL            THEN 'string'
        WHEN m.dataAbsentReason IS NOT NULL THEN 'absent'
    END                                                     AS value_type,
    m.v_qty.value                                           AS value_numeric,
    m.v_qty.code                                            AS value_unit_ucum,
    try_element_at(m.v_cc.coding, 1).code                   AS value_code,
    try_element_at(m.v_cc.coding, 1).system                 AS value_code_system,
    try_element_at(m.v_cc.coding, 1).display                AS value_display,
    m.v_str                                                 AS value_text,
    try_element_at(m.dataAbsentReason.coding, 1).code       AS data_absent_reason,
    TRY_CAST(m.effectiveDateTime AS TIMESTAMP)              AS effective_ts,
    TRY_CAST(m.meta.lastUpdated AS TIMESTAMP)               AS last_updated,
    m.source_file
FROM measured m
LEFT JOIN encounter_flat e
       ON e.encounter_id = m.encounter_ref_id;
