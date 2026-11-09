-- =============================================================================
-- 20_load_report.sql
-- What the incremental load did, and why event-time replay matters.
-- =============================================================================
\pset footer off

\echo '== Batch scorecard (one row per daily drop) =='
SELECT batch_id, run_no AS run, status, rows_landed AS landed, rows_quarantined AS quarantined,
       dup_control_id AS dup_ctl, dup_content AS dup_content,
       events_applied AS applied, late_events AS late,
       encounters_inserted AS enc_new, encounters_updated AS enc_changed,
       encounters_unchanged AS enc_same
FROM etl.batch_log ORDER BY batch_id, run_no;

\echo '== Landing row dispositions =='
SELECT disposition, COALESCE(reason, '-') AS reason, count(*) AS rows
FROM etl.event_disposition GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== Late-arriving events: how far behind the published state they were =='
SELECT event_type, count(*) AS late_events,
       round(avg(extract(epoch FROM late_by) / 3600)::numeric, 1) AS avg_hours_behind,
       round(max(extract(epoch FROM late_by) / 3600)::numeric, 1) AS max_hours_behind
FROM core.encounter_event WHERE is_late
GROUP BY event_type ORDER BY late_events DESC;

\echo '== Current encounter census by status =='
SELECT status, patient_class, count(*) AS encounters
FROM core.encounter GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== SCD2 history: versions by change cause =='
SELECT change_cause, count(*) AS versions
FROM core.encounter_history GROUP BY 1 ORDER BY 1;

\echo '== Reconciliation: warehouse vs. ground truth =='
SELECT count(*)                                                     AS expected_encounters,
       count(c.encounter_key)                                       AS loaded_encounters,
       count(*) FILTER (WHERE c.encounter_key IS NULL
                          OR (x.status, x.patient_class, x.admit_ts, x.discharge_ts,
                              x.location, x.attending_npi, x.mrn)
                             IS DISTINCT FROM
                             (c.status, c.patient_class, c.admit_ts, c.discharge_ts,
                              c.location, c.attending_npi, c.mrn)) AS mismatched
FROM synthetic.expected_state x
LEFT JOIN core.encounter c USING (encounter_key);

\echo '== Counterfactual: naive "last message received wins" upsert =='
-- What a typical upsert keyed on visit number (no event-time ordering) would
-- have published from the same de-duplicated events.
WITH last_rcv AS (
    SELECT DISTINCT ON (encounter_key) encounter_key, location, attending_npi
    FROM core.encounter_event ORDER BY encounter_key, received_ts DESC, event_id DESC
),
last_status AS (
    SELECT DISTINCT ON (encounter_key) encounter_key,
           CASE event_type WHEN 'A01' THEN 'ADMITTED' WHEN 'A04' THEN 'REGISTERED'
                           WHEN 'A03' THEN 'DISCHARGED' WHEN 'A11' THEN 'CANCELLED'
                           WHEN 'A13' THEN core.default_status(patient_class) END AS status
    FROM core.encounter_event
    WHERE event_type IN ('A01','A04','A03','A11','A13')
    ORDER BY encounter_key, received_ts DESC, event_id DESC
)
SELECT count(*) FILTER (WHERE s.status IS DISTINCT FROM x.status)               AS wrong_status,
       count(*) FILTER (WHERE r.location IS DISTINCT FROM x.location)           AS wrong_location,
       count(*) FILTER (WHERE r.attending_npi IS DISTINCT FROM x.attending_npi) AS wrong_attending,
       count(*) FILTER (WHERE s.status IS DISTINCT FROM x.status
                           OR r.location IS DISTINCT FROM x.location
                           OR r.attending_npi IS DISTINCT FROM x.attending_npi) AS encounters_wrong
FROM synthetic.expected_state x
LEFT JOIN last_rcv r    USING (encounter_key)
LEFT JOIN last_status s USING (encounter_key);
