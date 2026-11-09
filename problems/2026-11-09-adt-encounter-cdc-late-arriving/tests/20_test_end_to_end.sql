-- =============================================================================
-- 20_test_end_to_end.sql
-- Runs after scripts/run_demo.sh: the full synthetic feed (late, redelivered,
-- resent and junk messages, plus a re-dropped file) must reconcile exactly to
-- the ground truth built from the encounter plan.
-- =============================================================================

SELECT t.assert_eq('every batch run succeeded',
    (SELECT count(*) FROM etl.batch_log WHERE status <> 'SUCCEEDED'), 0::bigint);

SELECT t.assert_eq('every expected encounter loaded',
    (SELECT count(*) FROM core.encounter), (SELECT count(*) FROM synthetic.expected_state));

SELECT t.assert_eq('final state matches ground truth for every encounter',
    (SELECT count(*) FROM synthetic.expected_state x
     LEFT JOIN core.encounter c USING (encounter_key)
     WHERE (x.status, x.patient_class, x.admit_ts, x.discharge_ts,
            x.location, x.attending_npi, x.mrn)
           IS DISTINCT FROM
           (c.status, c.patient_class, c.admit_ts, c.discharge_ts,
            c.location, c.attending_npi, c.mrn)), 0::bigint);

SELECT t.assert_eq('each true event applied exactly once',
    (SELECT count(*) FROM core.encounter_event),
    (SELECT count(*) FROM synthetic.clean_event));

SELECT t.assert_eq('no true event missing from the log',
    (SELECT count(*) FROM synthetic.clean_event c
     WHERE NOT EXISTS (SELECT 1 FROM core.encounter_event e
                       WHERE e.msg_control_id = c.msg_control_id)), 0::bigint);

SELECT t.assert_eq('every landing row has one disposition',
    (SELECT count(*) FROM landing.adt_event), (SELECT count(*) FROM etl.event_disposition));

SELECT t.assert_eq('all resends classified DUP_CONTENT',
    (SELECT count(*) FROM etl.event_disposition d JOIN landing.adt_event l USING (landing_id)
     WHERE l.msg_control_id LIKE '%-R' AND d.disposition <> 'DUP_CONTENT'), 0::bigint);

SELECT t.assert_eq('all junk rows quarantined (8 seeded + 3 re-dropped)',
    (SELECT count(*) FROM etl.event_disposition WHERE disposition = 'QUARANTINED'), 11::bigint);

SELECT t.assert_eq('re-dropped 2026-11-02 file applied nothing',
    (SELECT events_applied FROM etl.batch_log WHERE batch_id = '2026-11-02' AND run_no = 2), 0);

SELECT t.assert_true('late arrivals were present and detected',
    (SELECT count(*) FROM core.encounter_event WHERE is_late) > 0);

SELECT t.assert_eq('late flag agrees with event-time vs. publish order',
    (SELECT count(*) FROM core.encounter_event e
     WHERE e.is_late AND e.late_by <= interval '0'), 0::bigint);

SELECT t.assert_eq('one current history row per encounter',
    (SELECT count(*) FROM core.encounter_history WHERE is_current),
    (SELECT count(*) FROM core.encounter));

SELECT t.assert_eq('history versions contiguous',
    (SELECT count(*) FROM core.encounter_history a JOIN core.encounter_history b
       ON b.encounter_key = a.encounter_key AND b.version_no = a.version_no + 1
     WHERE a.valid_to_batch IS DISTINCT FROM b.valid_from_batch), 0::bigint);

-- Replaying the log from scratch in a different arrival order must give the
-- same answer: re-fold every encounter and compare with the stored state.
SELECT t.assert_eq('re-fold of full log reproduces stored state',
    (SELECT count(*) FROM core.encounter c
     CROSS JOIN LATERAL core.fold_encounter(c.encounter_key) f
     WHERE f.state_hash <> c.state_hash), 0::bigint);
