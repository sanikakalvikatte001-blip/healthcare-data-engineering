-- =============================================================================
-- 10_test_scenarios.sql
-- Hand-built ADT scenarios with known answers. Runs on an empty schema.
-- Day 1 = 2026-11-01 batch, Day 2 = 2026-11-02 batch.
-- =============================================================================

-- ---------------------------------------------------------------- Day 1 feed
-- S1  discharge arrives before its admit (A01 comes in Day 2)
SELECT t.land('2026-11-01', 'S1-2', 'A03', 'S1', '2026-11-01 20:00');
-- S2  transfer MED -> ICU at 14:00; an older transfer (10:00 -> TELE) shows up Day 2
SELECT t.land('2026-11-01', 'S2-1', 'A01', 'S2', '2026-11-01 08:00', 'MED-4W');
SELECT t.land('2026-11-01', 'S2-3', 'A02', 'S2', '2026-11-01 14:00', 'ICU-2');
-- S3  admit then cancel, same day
SELECT t.land('2026-11-01', 'S3-1', 'A01', 'S3', '2026-11-01 08:00');
SELECT t.land('2026-11-01', 'S3-2', 'A11', 'S3', '2026-11-01 08:30');
-- S4  cancel arrives first, the admit it cancels arrives Day 2
SELECT t.land('2026-11-01', 'S4-2', 'A11', 'S4', '2026-11-01 08:30');
-- S5  admit + discharge Day 1, discharge cancelled (A13) Day 2
SELECT t.land('2026-11-01', 'S5-1', 'A01', 'S5', '2026-11-01 08:00');
SELECT t.land('2026-11-01', 'S5-2', 'A03', 'S5', '2026-11-01 12:00');
-- S6  admit + attending change at 20:00; the 15:00 discharge is late (Day 2)
SELECT t.land('2026-11-01', 'S6-1', 'A01', 'S6', '2026-11-01 08:00', p_attending => '1111111111');
SELECT t.land('2026-11-01', 'S6-3', 'A08', 'S6', '2026-11-01 20:00', p_attending => '2222222222');
-- S7  outpatient registration (redelivered and resent on Day 2)
SELECT t.land('2026-11-01', 'S7-1', 'A04', 'S7', '2026-11-01 09:00', 'CLINIC-A', p_class => 'O',
              p_admit_ts => '2026-11-01 09:00');
-- S8  same message delivered twice inside one batch
SELECT t.land('2026-11-01', 'S8-1', 'A01', 'S8', '2026-11-01 10:00', p_received_ts => '2026-11-01 10:01');
SELECT t.land('2026-11-01', 'S8-1', 'A01', 'S8', '2026-11-01 10:00', p_received_ts => '2026-11-01 10:30');
-- S9  structurally bad rows
SELECT t.land('2026-11-01', 'S9-a', 'A01', NULL,  '2026-11-01 11:00');                  -- no PV1-19
SELECT t.land('2026-11-01', 'S9-b', 'A28', 'S9b', '2026-11-01 11:00');                  -- not an encounter event
SELECT t.land('2026-11-01', 'S9-c', 'A03', 'S9c', '2026-11-01 07:00');                  -- discharge < admit (08:00)
SELECT t.land('2026-11-01', 'S9-d', 'A01', 'S9d', '2026-11-01 23:30');                  -- after receipt (23:00)

CALL etl.load_adt_batch('2026-11-01');

SELECT t.assert_eq('day1: batch succeeded',
    (SELECT status FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 1), 'SUCCEEDED');
SELECT t.assert_eq('day1: rows landed',       (SELECT rows_landed      FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 1), 17);
SELECT t.assert_eq('day1: rows quarantined',  (SELECT rows_quarantined FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 1), 4);
SELECT t.assert_eq('day1: in-batch duplicate', (SELECT dup_control_id  FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 1), 1);
SELECT t.assert_eq('day1: events applied',    (SELECT events_applied   FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 1), 12);
SELECT t.assert_eq('day1: encounters created', (SELECT encounters_inserted FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 1), 8);

SELECT t.assert_eq('S1 discharge-only encounter is DISCHARGED', (t.enc('S1')).status, 'DISCHARGED');
SELECT t.assert_eq('S1 admit_ts taken from PV1-44 snapshot', (t.enc('S1')).admit_ts, '2026-11-01 08:00'::timestamp);
SELECT t.assert_eq('S4 cancel-only encounter is CANCELLED', (t.enc('S4')).status, 'CANCELLED');
SELECT t.assert_eq('S5 discharged after day 1', (t.enc('S5')).status, 'DISCHARGED');
SELECT t.assert_eq('S6 admitted after day 1', (t.enc('S6')).status, 'ADMITTED');
SELECT t.assert_eq('S8 applied once', (t.enc('S8')).event_count, 1);

SELECT t.assert_eq('S9 each quarantine reason fires once',
    (SELECT string_agg(reason, ',' ORDER BY reason) FROM etl.event_disposition
     WHERE disposition = 'QUARANTINED'),
    'DISCHARGE_BEFORE_ADMIT,EVENT_AFTER_RECEIPT,MISSING_KEY_FIELD,UNSUPPORTED_EVENT_TYPE');
SELECT t.assert_eq('S9 quarantined rows never reach core',
    (SELECT count(*) FROM core.encounter WHERE visit_number IN ('S9b','S9c','S9d')), 0::bigint);

-- ---------------------------------------------------------------- Day 2 feed
SELECT t.land('2026-11-02', 'S1-1', 'A01', 'S1', '2026-11-01 08:00');                   -- late admit
SELECT t.land('2026-11-02', 'S2-2', 'A02', 'S2', '2026-11-01 10:00', 'TELE-5');          -- stale transfer
SELECT t.land('2026-11-02', 'S4-1', 'A01', 'S4', '2026-11-01 08:00');                   -- late admit
SELECT t.land('2026-11-02', 'S5-3', 'A13', 'S5', '2026-11-02 09:00');                   -- cancel discharge
SELECT t.land('2026-11-02', 'S6-2', 'A03', 'S6', '2026-11-01 15:00', p_attending => '1111111111'); -- late discharge
SELECT t.land('2026-11-02', 'S7-1', 'A04', 'S7', '2026-11-01 09:00', 'CLINIC-A', p_class => 'O',
              p_admit_ts => '2026-11-01 09:00');                                         -- redelivery
SELECT t.land('2026-11-02', 'S7-1-R', 'A04', 'S7', '2026-11-01 09:00', 'CLINIC-A', p_class => 'O',
              p_admit_ts => '2026-11-01 09:00');                                         -- resend, new MSH-10

CALL etl.load_adt_batch('2026-11-02');

SELECT t.assert_eq('day2: events applied', (SELECT events_applied FROM etl.batch_log WHERE batch_id = '2026-11-02'), 5);
SELECT t.assert_eq('day2: late events',    (SELECT late_events    FROM etl.batch_log WHERE batch_id = '2026-11-02'), 4);
SELECT t.assert_eq('day2: dup control id', (SELECT dup_control_id FROM etl.batch_log WHERE batch_id = '2026-11-02'), 1);
SELECT t.assert_eq('day2: dup content',    (SELECT dup_content    FROM etl.batch_log WHERE batch_id = '2026-11-02'), 1);

-- S1: late admit is slotted in before the discharge; state is unchanged.
SELECT t.assert_eq('S1 still DISCHARGED after late A01', (t.enc('S1')).status, 'DISCHARGED');
SELECT t.assert_eq('S1 late A01 flagged 12h behind',
    (SELECT late_by FROM core.encounter_event WHERE msg_control_id = 'S1-1'), interval '12 hours');
SELECT t.assert_eq('S1 no new history version (state did not change)',
    (SELECT count(*) FROM core.encounter_history WHERE encounter_key = 'TST|S1'), 1::bigint);

-- S2: the stale transfer must not overwrite the newer location.
SELECT t.assert_eq('S2 location stays ICU-2', (t.enc('S2')).location, 'ICU-2');
SELECT t.assert_eq('S2 three events in log',  (t.enc('S2')).event_count, 3);

SELECT t.assert_eq('S3 admit then cancel = CANCELLED', (t.enc('S3')).status, 'CANCELLED');

-- S4: cancel happened after the admit in real time, so the visit stays cancelled
-- (a "last message received wins" load would flip it back to ADMITTED).
SELECT t.assert_eq('S4 still CANCELLED after late A01', (t.enc('S4')).status, 'CANCELLED');

SELECT t.assert_eq('S5 A13 reopens encounter', (t.enc('S5')).status, 'ADMITTED');
SELECT t.assert_eq('S5 A13 clears discharge_ts', (t.enc('S5')).discharge_ts, NULL::timestamp);
SELECT t.assert_eq('S5 change recorded as IN_ORDER',
    (SELECT change_cause FROM core.encounter_history WHERE encounter_key = 'TST|S5' AND is_current), 'IN_ORDER');

-- S6: late discharge changes status but the later A08 attending is kept.
SELECT t.assert_eq('S6 late A03 -> DISCHARGED', (t.enc('S6')).status, 'DISCHARGED');
SELECT t.assert_eq('S6 discharge_ts from late A03', (t.enc('S6')).discharge_ts, '2026-11-01 15:00'::timestamp);
SELECT t.assert_eq('S6 attending from newer A08 kept', (t.enc('S6')).attending_npi, '2222222222');
SELECT t.assert_eq('S6 change recorded as LATE_CORRECTION',
    (SELECT change_cause FROM core.encounter_history WHERE encounter_key = 'TST|S6' AND is_current),
    'LATE_CORRECTION');
SELECT t.assert_eq('S6 prior version closed by day-2 batch',
    (SELECT valid_to_batch FROM core.encounter_history WHERE encounter_key = 'TST|S6' AND version_no = 1),
    '2026-11-02'::date);

-- S7: both copies are linked back to the one applied event.
SELECT t.assert_eq('S7 single event despite 3 deliveries', (t.enc('S7')).event_count, 1);
SELECT t.assert_eq('S7 all deliveries point at same event',
    (SELECT count(DISTINCT d.event_id) FROM etl.event_disposition d
     JOIN landing.adt_event l USING (landing_id) WHERE l.visit_number = 'S7'), 1::bigint);

-- ------------------------------------------------- Idempotency: file re-drop
CREATE TEMP TABLE before_replay AS
SELECT md5(string_agg(e::text, '' ORDER BY encounter_key)) AS enc_hash,
       (SELECT count(*) FROM core.encounter_history) AS history_rows,
       (SELECT count(*) FROM core.encounter_event)   AS event_rows
FROM core.encounter e;

INSERT INTO landing.adt_event (batch_id, source_system, msg_control_id, event_type, event_ts,
       received_ts, facility, visit_number, mrn, patient_class, location, attending_npi,
       admit_ts, discharge_ts)
SELECT batch_id, source_system, msg_control_id, event_type, event_ts, received_ts, facility,
       visit_number, mrn, patient_class, location, attending_npi, admit_ts, discharge_ts
FROM landing.adt_event WHERE batch_id = '2026-11-01';

CALL etl.load_adt_batch('2026-11-01');

SELECT t.assert_eq('replay: logged as run 2',
    (SELECT max(run_no) FROM etl.batch_log WHERE batch_id = '2026-11-01'), 2);
SELECT t.assert_eq('replay: nothing applied',
    (SELECT events_applied FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 2), 0);
SELECT t.assert_eq('replay: core.encounter byte-identical',
    (SELECT md5(string_agg(e::text, '' ORDER BY encounter_key)) FROM core.encounter e),
    (SELECT enc_hash FROM before_replay));
SELECT t.assert_eq('replay: no new history rows',
    (SELECT count(*) FROM core.encounter_history), (SELECT history_rows FROM before_replay));
SELECT t.assert_eq('replay: no new events',
    (SELECT count(*) FROM core.encounter_event), (SELECT event_rows FROM before_replay));

-- A second call with nothing new is a no-op as well.
CALL etl.load_adt_batch('2026-11-01');
SELECT t.assert_eq('empty re-run lands 0 rows',
    (SELECT rows_landed FROM etl.batch_log WHERE batch_id = '2026-11-01' AND run_no = 3), 0);

-- ------------------------------------------------------- Structural invariants
SELECT t.assert_eq('every landing row has exactly one disposition',
    (SELECT count(*) FROM landing.adt_event l
     LEFT JOIN etl.event_disposition d USING (landing_id) WHERE d.landing_id IS NULL), 0::bigint);
SELECT t.assert_eq('exactly one current history row per encounter',
    (SELECT count(*) FROM core.encounter_history WHERE is_current),
    (SELECT count(*) FROM core.encounter));
SELECT t.assert_eq('current history hash = current state hash',
    (SELECT count(*) FROM core.encounter c JOIN core.encounter_history h
       ON h.encounter_key = c.encounter_key AND h.is_current
     WHERE h.state_hash <> c.state_hash), 0::bigint);
SELECT t.assert_eq('history versions are contiguous',
    (SELECT count(*) FROM core.encounter_history a JOIN core.encounter_history b
       ON b.encounter_key = a.encounter_key AND b.version_no = a.version_no + 1
     WHERE a.valid_to_batch IS DISTINCT FROM b.valid_from_batch), 0::bigint);

-- ------------------------------------------------- Failure path keeps a log row
-- Force the MERGE to fail with a temporary CHECK constraint, then confirm the
-- batch is logged FAILED, nothing partial is left behind, and a retry works.
ALTER TABLE core.encounter ADD CONSTRAINT tmp_block_visit CHECK (visit_number <> 'BOOM');
SELECT t.land('2026-11-03', 'BOOM-1', 'A01', 'BOOM', '2026-11-03 08:00');
CALL etl.load_adt_batch('2026-11-03');
SELECT t.assert_eq('failed batch logged as FAILED',
    (SELECT status FROM etl.batch_log WHERE batch_id = '2026-11-03'), 'FAILED');
SELECT t.assert_eq('failed batch rolled back its events',
    (SELECT count(*) FROM core.encounter_event WHERE visit_number = 'BOOM'), 0::bigint);
SELECT t.assert_eq('failed batch rows left undispositioned for retry',
    (SELECT count(*) FROM etl.event_disposition d JOIN landing.adt_event l USING (landing_id)
     WHERE l.visit_number = 'BOOM'), 0::bigint);
ALTER TABLE core.encounter DROP CONSTRAINT tmp_block_visit;
CALL etl.load_pending_batches();
SELECT t.assert_eq('retry after fix succeeds',
    (SELECT status FROM etl.batch_log WHERE batch_id = '2026-11-03' ORDER BY run_no DESC LIMIT 1),
    'SUCCEEDED');
