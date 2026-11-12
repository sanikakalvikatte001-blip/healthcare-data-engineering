-- =====================================================================================
-- Load the C# ingestion outputs into a DuckDB warehouse schema and reconcile them.
-- Independent SQL check of the C# logic: the dedup is recomputed set-based here and must
-- match the curated tables the C# pipeline wrote. Run from the project folder:
--   python3 sql/run_sql_checks.py
-- =====================================================================================

CREATE OR REPLACE TABLE ccda_document_manifest AS
SELECT * FROM read_csv('output/state/document_manifest.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE ccda_document_entry AS
SELECT * FROM read_csv('output/state/document_entries.csv', header = true, all_varchar = true);

-- Curated tables get real primary keys: a duplicate natural key makes the INSERT fail outright.
CREATE OR REPLACE TABLE curated_problem (
    patient_key VARCHAR NOT NULL, code VARCHAR NOT NULL, code_system VARCHAR NOT NULL, display VARCHAR,
    status VARCHAR, effective_start VARCHAR, effective_end VARCHAR, value VARCHAR, unit VARCHAR,
    source_document_count INTEGER, first_seen_document_id VARCHAR, last_seen_document_id VARCHAR,
    PRIMARY KEY (patient_key, code_system, code));
INSERT INTO curated_problem SELECT * FROM read_csv('output/curated/curated_problems.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE curated_allergy AS SELECT * FROM curated_problem WHERE false;
ALTER TABLE curated_allergy ADD PRIMARY KEY (patient_key, code_system, code);
INSERT INTO curated_allergy SELECT * FROM read_csv('output/curated/curated_allergies.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE curated_medication AS SELECT * FROM curated_problem WHERE false;
ALTER TABLE curated_medication ADD PRIMARY KEY (patient_key, code_system, code, effective_start);
INSERT INTO curated_medication SELECT * FROM read_csv('output/curated/curated_medications.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE curated_result AS SELECT * FROM curated_problem WHERE false;
ALTER TABLE curated_result ADD PRIMARY KEY (patient_key, code_system, code, effective_start);
INSERT INTO curated_result SELECT * FROM read_csv('output/curated/curated_results.csv', header = true, all_varchar = true);

CREATE OR REPLACE VIEW curated_all AS
SELECT 'Problem' AS entry_type, * FROM curated_problem
UNION ALL SELECT 'Medication', * FROM curated_medication
UNION ALL SELECT 'Allergy', * FROM curated_allergy
UNION ALL SELECT 'Result', * FROM curated_result;

-- Set-based re-derivation of the curated layer: latest active document wins per natural key.
CREATE OR REPLACE VIEW expected_curated AS
WITH active_entry AS (
    SELECT e.*,
           CASE WHEN e.entry_type IN ('Medication', 'Result')
                THEN concat_ws('|', e.code_system, e.code, e.effective_start)
                ELSE concat_ws('|', e.code_system, e.code) END AS natural_key
    FROM ccda_document_entry e
    JOIN ccda_document_manifest m ON m.document_id = e.document_id AND m.status = 'Loaded'
), ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY patient_key, entry_type, natural_key
                              ORDER BY document_time DESC, document_id DESC) AS rn,
           count(DISTINCT document_id) OVER (PARTITION BY patient_key, entry_type, natural_key) AS doc_count
    FROM active_entry
)
SELECT entry_type, patient_key, code, code_system, status, effective_start, effective_end, value,
       doc_count::INTEGER AS source_document_count, document_id AS last_seen_document_id
FROM ranked WHERE rn = 1;

-- ---------------------------------------------------------------- reconciliation checks
CREATE OR REPLACE TABLE reconciliation_result AS
WITH inbox AS (SELECT count(*) AS n FROM glob('data/inbox/*/*.xml'))
SELECT 'every inbox file has exactly one manifest row' AS check_name,
       (SELECT n FROM inbox)::VARCHAR AS expected,
       (SELECT count(DISTINCT batch_id || '/' || file_name) FROM ccda_document_manifest)::VARCHAR AS actual
UNION ALL
SELECT 'at most one Loaded document per set_id', '0',
       (SELECT count(*) FROM (SELECT set_id FROM ccda_document_manifest WHERE status = 'Loaded'
                              GROUP BY set_id HAVING count(*) > 1))::VARCHAR
UNION ALL
SELECT 'every DuplicateFile hash belongs to an earlier accepted-or-logged file', '0',
       (SELECT count(*) FROM ccda_document_manifest d
        WHERE d.status = 'DuplicateFile'
          AND NOT EXISTS (SELECT 1 FROM ccda_document_manifest o
                          WHERE o.file_sha256 = d.file_sha256 AND o.status <> 'DuplicateFile'))::VARCHAR
UNION ALL
SELECT 'no raw entries from rejected / stale / duplicate documents', '0',
       (SELECT count(*) FROM ccda_document_entry e
        WHERE NOT EXISTS (SELECT 1 FROM ccda_document_manifest m
                          WHERE m.document_id = e.document_id AND m.status IN ('Loaded', 'Superseded')))::VARCHAR
UNION ALL
SELECT 'curated row count = SQL re-derivation',
       (SELECT count(*) FROM expected_curated)::VARCHAR, (SELECT count(*) FROM curated_all)::VARCHAR
UNION ALL
SELECT 'curated rows differing from SQL re-derivation', '0',
       (SELECT count(*) FROM (
            SELECT entry_type, patient_key, code, code_system, status, effective_start, effective_end, value,
                   source_document_count, last_seen_document_id FROM curated_all
            EXCEPT
            SELECT entry_type, patient_key, code, code_system, status, effective_start, effective_end, value,
                   source_document_count, last_seen_document_id FROM expected_curated))::VARCHAR
UNION ALL
SELECT 'curated rows sourced only from active (Loaded) documents', '0',
       (SELECT count(*) FROM curated_all c
        WHERE NOT EXISTS (SELECT 1 FROM ccda_document_manifest m
                          WHERE m.document_id = c.last_seen_document_id AND m.status = 'Loaded'))::VARCHAR;

SELECT check_name, expected, actual, expected = actual AS passed FROM reconciliation_result;
