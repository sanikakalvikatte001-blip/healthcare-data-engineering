-- =============================================================================
-- 01_patient.sql : Patient -> patient_flat (one row per patient)
-- Input : raw_patient (all Patient.*.ndjson lines, explicit schema)
-- =============================================================================

-- A bulk export can contain the same Patient more than once (re-exports, files
-- produced by parallel workers). Keep the highest meta.versionId; break ties on
-- lastUpdated. File order is NOT trusted - the newest version may sit in an
-- earlier file.
CREATE OR REPLACE TEMP VIEW patient_latest AS
SELECT *
FROM (
    SELECT p.*,
           ROW_NUMBER() OVER (
               PARTITION BY id
               ORDER BY TRY_CAST(meta.versionId AS INT) DESC,
                        TRY_CAST(meta.lastUpdated AS TIMESTAMP) DESC,
                        source_file DESC
           ) AS version_rank
    FROM raw_patient p
    WHERE _corrupt_record IS NULL
      AND resourceType = 'Patient'
      AND id IS NOT NULL
) ranked
WHERE version_rank = 1;


-- Flatten the repeating elements with higher-order functions (filter / exists)
-- instead of exploding them: one row per patient stays one row per patient.
CREATE OR REPLACE TEMP VIEW patient_flat AS
WITH picked AS (
    SELECT
        p.*,
        -- Prefer the official name; some EHRs list a nickname first.
        COALESCE(try_element_at(filter(name, n -> n.use = 'official'), 1),
                 try_element_at(name, 1))                                       AS nm,
        -- The MRN is the identifier whose type is v2-0203 'MR', wherever it sits.
        try_element_at(filter(identifier,
                              i -> exists(i.`type`.coding, c -> c.code = 'MR')), 1) AS mr,
        try_element_at(filter(telecom, t -> t.system = 'phone'), 1)             AS phone,
        COALESCE(try_element_at(filter(address, a -> a.use = 'home'), 1),
                 try_element_at(address, 1))                                    AS addr
    FROM patient_latest p
)
SELECT
    id                                                        AS patient_id,
    mr.value                                                  AS mrn,
    mr.system                                                 AS mrn_system,
    nm.family                                                 AS family_name,
    try_element_at(nm.given, 1)                               AS given_name,
    CASE WHEN size(nm.given) > 1
         THEN array_join(slice(nm.given, 2, size(nm.given) - 1), ' ')
    END                                                       AS middle_names,
    TRY_CAST(birthDate AS DATE)                               AS birth_date,
    gender,
    try_element_at(filter(extension,
                          e -> e.url LIKE '%/us-core-birthsex'), 1).valueCode AS birth_sex,
    phone.value                                               AS phone_home,
    addr.state                                                AS state,
    addr.postalCode                                           AS postal_code,
    COALESCE(deceasedBoolean, FALSE)                          AS is_deceased,
    TRY_CAST(meta.versionId AS INT)                           AS version_id,
    TRY_CAST(meta.lastUpdated AS TIMESTAMP)                   AS last_updated,
    source_file
FROM picked;
