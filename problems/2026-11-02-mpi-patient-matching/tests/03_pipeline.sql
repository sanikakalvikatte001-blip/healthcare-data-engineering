-- pgTAP: end-to-end properties of the MPI after `make run`
-- Everything runs inside a transaction and is rolled back.
BEGIN;
SELECT plan(17);

-- ---------------------------------------------------------------------------
-- Integrity
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM mpi.source_patient sp
           LEFT JOIN mpi.enterprise_patient ep USING (enterprise_id)
           WHERE ep.status IS DISTINCT FROM 'ACTIVE'),
          0, 'every source record points at an ACTIVE enterprise ID');

SELECT is((SELECT count(*)::int FROM mpi.source_patient WHERE needs_matching),
          0, 'no record left unmatched');

SELECT is((SELECT count(*)::int FROM mpi.enterprise_patient m
           JOIN mpi.enterprise_patient s ON s.enterprise_id = m.merged_into
           WHERE s.status <> 'ACTIVE'),
          0, 'merged IDs point directly at an active survivor (no chains)');

SELECT results_eq(
    $$SELECT reason, count(*)::int FROM mpi.registration_reject GROUP BY reason ORDER BY reason$$,
    $$VALUES ('INVALID_BIRTH_DATE', 2), ('MISSING_NAME', 1)$$,
    'unusable rows are rejected with a reason');

-- ---------------------------------------------------------------------------
-- Accuracy against the synthetic truth
-- ---------------------------------------------------------------------------
SELECT is((SELECT precision FROM mpi.v_pairwise_accuracy), 1.0000::numeric,
          'no false links (overlays)');
SELECT cmp_ok((SELECT recall FROM mpi.v_pairwise_accuracy), '>=', 0.93::numeric,
              'pairwise recall of automatic linking >= 0.93');
SELECT is((SELECT count(*)::int FROM mpi.v_family_overlays), 0,
          'twins and Jr/Sr pairs never share an enterprise ID');

-- Every missed link is waiting in the review queue: no silent duplicates.
SELECT is((
    SELECT count(*)::int
    FROM stg.synthetic_truth ta
    JOIN stg.synthetic_truth tb
      ON tb.true_person_id = ta.true_person_id
     AND (ta.source_system, ta.source_patient_id) < (tb.source_system, tb.source_patient_id)
    JOIN mpi.source_patient a ON (a.source_system, a.source_patient_id) = (ta.source_system, ta.source_patient_id)
    JOIN mpi.source_patient b ON (b.source_system, b.source_patient_id) = (tb.source_system, tb.source_patient_id)
    WHERE a.enterprise_id <> b.enterprise_id
      AND NOT EXISTS (
          SELECT 1 FROM mpi.review_queue q
          JOIN mpi.source_patient qa ON (qa.source_system, qa.source_patient_id) = (q.a_system, q.a_id)
          JOIN mpi.source_patient qb ON (qb.source_system, qb.source_patient_id) = (q.b_system, q.b_id)
          WHERE (qa.enterprise_id, qb.enterprise_id) IN ((a.enterprise_id, b.enterprise_id),
                                                          (b.enterprise_id, a.enterprise_id)))),
    0, 'every split person has a review item joining their two enterprise IDs');

SELECT is((SELECT count(*)::int FROM mpi.review_queue WHERE reason = 'SAME_SOURCE_DUPLICATE'),
          12, 'all 12 duplicate EHR charts are queued, not auto-linked');

-- ---------------------------------------------------------------------------
-- Resends: the latest message wins and identity is sticky
-- ---------------------------------------------------------------------------
SELECT matches((SELECT phone::text FROM mpi.source_patient WHERE source_patient_id = 'E000301'),
               '^64655501', 'later resend wins over the earlier one in the same batch');

SELECT is((SELECT enterprise_id FROM mpi.source_patient WHERE source_patient_id = 'E000301'),
          (SELECT enterprise_id FROM mpi.link_audit
            WHERE source_patient_id = 'E000301' AND event = 'NEW_ENTERPRISE_ID'),
          'a demographic update keeps the original enterprise ID');

-- ---------------------------------------------------------------------------
-- Idempotency: re-running a batch changes nothing
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE before_rerun AS
SELECT (SELECT count(*) FROM mpi.enterprise_patient) AS ids,
       (SELECT count(*) FROM mpi.link_audit)         AS audits,
       (SELECT count(*) FROM mpi.review_queue)       AS reviews,
       (SELECT md5(string_agg(source_system || source_patient_id || enterprise_id, ',' ORDER BY 1))
          FROM mpi.source_patient)                   AS xref;
CALL mpi.process_batch('B20261102');
SELECT results_eq(
    $$SELECT (SELECT count(*) FROM mpi.enterprise_patient), (SELECT count(*) FROM mpi.link_audit),
             (SELECT count(*) FROM mpi.review_queue),
             (SELECT md5(string_agg(source_system || source_patient_id || enterprise_id, ',' ORDER BY 1))
                FROM mpi.source_patient)$$,
    $$SELECT ids, audits, reviews, xref FROM before_rerun$$,
    're-running B20261102 is a no-op');

-- ---------------------------------------------------------------------------
-- Bridging record merges two enterprise IDs
--   BT1: payer record (SSN, no phone) and lab record (phone, no SSN, DOB
--        keyed day/month swapped) - not enough to link them to each other.
--   BT2: EHR chart that matches both -> the two IDs are merged.
-- ---------------------------------------------------------------------------
INSERT INTO stg.patient_registration
    (batch_id, source_system, source_patient_id, first_name, last_name, birth_date_raw,
     sex_raw, ssn_raw, phone_raw, address_line, zip_raw, received_at)
VALUES
    ('BT1', 'CLAIMS_PAYER', 'MT1', 'ABIGAIL', 'FAIRBANKS', '19790605', '2', '977551234',
     NULL, '88 ORCHARD LANE', '13555', '2026-11-03 01:00+00'),
    ('BT1', 'LAB_LIS', 'LT1', 'ABBY', 'FAIRBANKS', '05/06/1979', 'Female', NULL,
     '3155550177', NULL, NULL, '2026-11-03 01:05+00'),
    ('BT2', 'EHR_EPIC', 'ET1', 'Abigail', 'Fairbanks', '1979-06-05', 'F', '977-55-1234',
     '(315) 555-0177', '88 Orchard Lane', '13555', '2026-11-04 01:00+00');

CALL mpi.process_batch('BT1');
SELECT isnt((SELECT enterprise_id FROM mpi.source_patient WHERE source_patient_id = 'MT1'),
            (SELECT enterprise_id FROM mpi.source_patient WHERE source_patient_id = 'LT1'),
            'BT1: weak evidence alone does not link payer and lab records');

CALL mpi.process_batch('BT2');
SELECT is((SELECT count(DISTINCT enterprise_id)::int FROM mpi.source_patient
           WHERE source_patient_id IN ('MT1', 'LT1', 'ET1')),
          1, 'BT2: the EHR chart bridges both records onto one enterprise ID');
SELECT is((SELECT count(*)::int FROM mpi.link_audit WHERE batch_id = 'BT2' AND event = 'MERGE'),
          1, 'BT2: exactly one MERGE is audited');
SELECT is((SELECT ep.merged_into FROM mpi.enterprise_patient ep WHERE ep.merged_batch = 'BT2'),
          (SELECT enterprise_id FROM mpi.source_patient WHERE source_patient_id = 'ET1'),
          'BT2: the retired ID points at the survivor');
SELECT is((SELECT status FROM mpi.enterprise_patient ep
           JOIN mpi.source_patient sp USING (enterprise_id) WHERE sp.source_patient_id = 'ET1'),
          'ACTIVE', 'BT2: the survivor is the older, still-active ID');

SELECT * FROM finish();
ROLLBACK;
