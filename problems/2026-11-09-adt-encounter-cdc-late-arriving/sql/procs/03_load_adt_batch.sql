-- =============================================================================
-- 03_load_adt_batch.sql
-- Incremental load of one daily ADT batch:  landing -> core.
--
--   1. pick up landing rows in the batch that have no disposition yet
--      (so re-running a batch, or a file appended to it later, is safe)
--   2. quarantine rows that fail structural checks
--   3. drop redeliveries (same MSH-10) and resends (new MSH-10, same content)
--   4. append the rest to core.encounter_event, flagging late arrivals
--   5. re-fold every touched encounter in event-time order
--   6. SCD2 the published state, then MERGE into core.encounter
--   7. write the batch scorecard to etl.batch_log
-- =============================================================================

-- Business-content fingerprint: everything except transport metadata
-- (control id, receive time, batch). Two rows with the same hash are the
-- same clinical fact delivered twice.
CREATE OR REPLACE FUNCTION etl.adt_content_hash(
    p_source text, p_facility text, p_visit text, p_event_type text,
    p_event_ts timestamp, p_mrn text, p_class text, p_location text,
    p_attending text, p_admit_ts timestamp, p_discharge_ts timestamp)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT md5(concat_ws('|', p_source, p_facility, p_visit, p_event_type,
                         p_event_ts, p_mrn, p_class, p_location, p_attending,
                         p_admit_ts, p_discharge_ts))
$$;

CREATE OR REPLACE PROCEDURE etl.load_adt_batch(p_batch_id date)
LANGUAGE plpgsql AS $$
DECLARE
    v_landed      int;
    v_quarantined int;
    v_dup_ctl     int;
    v_dup_content int;
    v_applied     int;
    v_late        int;
    v_inserted    int;
    v_updated     int;
    v_unchanged   int;
    v_run_no      int;
BEGIN
    -- Register the run; earlier runs of the same batch keep their scorecards.
    INSERT INTO etl.batch_log (batch_id, run_no, status)
    SELECT p_batch_id, COALESCE(max(run_no), 0) + 1, 'RUNNING'
    FROM etl.batch_log WHERE batch_id = p_batch_id
    RETURNING run_no INTO v_run_no;

    BEGIN  -- sub-block: any error rolls back the load but keeps the FAILED log row
        DROP TABLE IF EXISTS pg_temp._incoming, pg_temp._prior, pg_temp._new_state;

        ---------------------------------------------------------------------
        -- 1 + 2. Unprocessed rows, with key, fingerprint and quarantine reason
        ---------------------------------------------------------------------
        CREATE TEMP TABLE _incoming AS
        SELECT l.*,
               l.facility || '|' || l.visit_number AS encounter_key,
               etl.adt_content_hash(l.source_system, l.facility, l.visit_number,
                   l.event_type, l.event_ts, l.mrn, l.patient_class, l.location,
                   l.attending_npi, l.admit_ts, l.discharge_ts) AS content_hash,
               CASE
                   WHEN l.msg_control_id IS NULL OR l.visit_number IS NULL
                     OR l.facility IS NULL OR l.event_ts IS NULL
                        THEN 'MISSING_KEY_FIELD'
                   WHEN l.event_type IS NULL
                     OR l.event_type NOT IN ('A01','A02','A03','A04','A08','A11','A13')
                        THEN 'UNSUPPORTED_EVENT_TYPE'
                   WHEN l.event_ts > l.received_ts + interval '5 minutes'
                        THEN 'EVENT_AFTER_RECEIPT'
                   WHEN l.event_type = 'A03' AND l.discharge_ts < l.admit_ts
                        THEN 'DISCHARGE_BEFORE_ADMIT'
               END AS quarantine_reason,
               NULL::text AS disposition
        FROM landing.adt_event l
        WHERE l.batch_id = p_batch_id
          AND NOT EXISTS (SELECT 1 FROM etl.event_disposition d
                          WHERE d.landing_id = l.landing_id);

        GET DIAGNOSTICS v_landed = ROW_COUNT;

        UPDATE _incoming SET disposition = 'QUARANTINED'
        WHERE quarantine_reason IS NOT NULL;

        ---------------------------------------------------------------------
        -- 3. Duplicates. First arrival wins inside the batch; anything already
        --    in the event log from an earlier batch is a duplicate outright.
        ---------------------------------------------------------------------
        WITH ranked AS (
            SELECT landing_id,
                   row_number() OVER (PARTITION BY source_system, msg_control_id
                                      ORDER BY received_ts, landing_id) AS rn
            FROM _incoming WHERE disposition IS NULL
        )
        UPDATE _incoming i SET disposition = 'DUP_CONTROL_ID'
        FROM ranked r
        WHERE i.landing_id = r.landing_id
          AND (r.rn > 1
               OR EXISTS (SELECT 1 FROM core.encounter_event e
                          WHERE e.source_system  = i.source_system
                            AND e.msg_control_id = i.msg_control_id));

        WITH ranked AS (
            SELECT landing_id,
                   row_number() OVER (PARTITION BY content_hash
                                      ORDER BY received_ts, landing_id) AS rn
            FROM _incoming WHERE disposition IS NULL
        )
        UPDATE _incoming i SET disposition = 'DUP_CONTENT'
        FROM ranked r
        WHERE i.landing_id = r.landing_id
          AND (r.rn > 1
               OR EXISTS (SELECT 1 FROM core.encounter_event e
                          WHERE e.content_hash = i.content_hash));

        UPDATE _incoming SET disposition = 'APPLIED' WHERE disposition IS NULL;

        ---------------------------------------------------------------------
        -- 4. Append new events. "Late" = older than the last event already
        --    published for that encounter, i.e. downstream saw a wrong state.
        ---------------------------------------------------------------------
        CREATE TEMP TABLE _prior AS
        SELECT c.encounter_key, c.last_event_ts, c.state_hash
        FROM core.encounter c
        WHERE c.encounter_key IN (SELECT encounter_key FROM _incoming
                                  WHERE disposition = 'APPLIED');

        INSERT INTO core.encounter_event (
            encounter_key, source_system, msg_control_id, content_hash, event_type,
            event_ts, received_ts, batch_id, facility, visit_number, mrn,
            patient_class, location, attending_npi, admit_ts, discharge_ts,
            is_late, late_by)
        SELECT i.encounter_key, i.source_system, i.msg_control_id, i.content_hash,
               i.event_type, i.event_ts, i.received_ts, i.batch_id, i.facility,
               i.visit_number, i.mrn, i.patient_class, i.location, i.attending_npi,
               i.admit_ts, i.discharge_ts,
               COALESCE(i.event_ts < p.last_event_ts, false),
               CASE WHEN i.event_ts < p.last_event_ts
                    THEN p.last_event_ts - i.event_ts END
        FROM _incoming i
        LEFT JOIN _prior p USING (encounter_key)
        WHERE i.disposition = 'APPLIED'
        ORDER BY i.received_ts, i.landing_id;

        GET DIAGNOSTICS v_applied = ROW_COUNT;

        -- Every landing row gets exactly one disposition (lineage to the event).
        INSERT INTO etl.event_disposition (landing_id, batch_id, disposition, reason, event_id)
        SELECT i.landing_id, i.batch_id, i.disposition, i.quarantine_reason,
               e.event_id
        FROM _incoming i
        LEFT JOIN core.encounter_event e
               ON  i.disposition IN ('APPLIED','DUP_CONTROL_ID')
               AND e.source_system  = i.source_system
               AND e.msg_control_id = i.msg_control_id
               AND i.msg_control_id IS NOT NULL;

        -- Content duplicates point at the event that carried the same content.
        UPDATE etl.event_disposition d
        SET event_id = e.event_id
        FROM _incoming i
        JOIN core.encounter_event e ON e.content_hash = i.content_hash
        WHERE d.landing_id = i.landing_id
          AND i.disposition = 'DUP_CONTENT';

        ---------------------------------------------------------------------
        -- 5. Re-fold each touched encounter in event-time order.
        ---------------------------------------------------------------------
        CREATE TEMP TABLE _new_state AS
        SELECT t.encounter_key,
               split_part(t.encounter_key, '|', 1) AS facility,
               split_part(t.encounter_key, '|', 2) AS visit_number,
               f.*,
               EXISTS (SELECT 1 FROM core.encounter_event e
                       WHERE e.encounter_key = t.encounter_key
                         AND e.batch_id = p_batch_id AND e.is_late) AS had_late
        FROM (SELECT DISTINCT encounter_key FROM _incoming
              WHERE disposition = 'APPLIED') t
        -- LATERAL so the fold runs once per encounter (not once per column)
        CROSS JOIN LATERAL core.fold_encounter(t.encounter_key) f;

        SELECT count(*) FILTER (WHERE p.encounter_key IS NULL),
               count(*) FILTER (WHERE p.state_hash <> n.state_hash),
               count(*) FILTER (WHERE p.state_hash =  n.state_hash)
          INTO v_inserted, v_updated, v_unchanged
        FROM _new_state n
        LEFT JOIN _prior p USING (encounter_key);

        ---------------------------------------------------------------------
        -- 6a. SCD2 history: close the current version, open a new one,
        --     only where the published state actually changed.
        ---------------------------------------------------------------------
        UPDATE core.encounter_history h
        SET valid_to_batch = p_batch_id, is_current = false
        FROM _new_state n
        WHERE h.encounter_key = n.encounter_key
          AND h.is_current
          AND h.state_hash <> n.state_hash;

        INSERT INTO core.encounter_history (
            encounter_key, version_no, status, patient_class, admit_ts, discharge_ts,
            location, attending_npi, state_hash, valid_from_batch, valid_to_batch,
            is_current, change_cause)
        SELECT n.encounter_key,
               COALESCE((SELECT max(version_no) FROM core.encounter_history h
                         WHERE h.encounter_key = n.encounter_key), 0) + 1,
               n.status, n.patient_class, n.admit_ts, n.discharge_ts,
               n.location, n.attending_npi, n.state_hash, p_batch_id, NULL, true,
               CASE WHEN p.encounter_key IS NULL THEN 'NEW'
                    WHEN n.had_late            THEN 'LATE_CORRECTION'
                    ELSE 'IN_ORDER' END
        FROM _new_state n
        LEFT JOIN _prior p USING (encounter_key)
        WHERE p.encounter_key IS NULL OR p.state_hash <> n.state_hash;

        ---------------------------------------------------------------------
        -- 6b. Upsert current state.
        ---------------------------------------------------------------------
        MERGE INTO core.encounter c
        USING _new_state n ON c.encounter_key = n.encounter_key
        WHEN MATCHED AND c.state_hash <> n.state_hash
                      OR c.event_count <> n.event_count THEN
            UPDATE SET mrn                = n.mrn,
                       patient_class      = n.patient_class,
                       status             = n.status,
                       admit_ts           = n.admit_ts,
                       discharge_ts       = n.discharge_ts,
                       location           = n.location,
                       attending_npi      = n.attending_npi,
                       last_event_ts      = n.last_event_ts,
                       event_count        = n.event_count,
                       last_changed_batch = CASE WHEN c.state_hash <> n.state_hash
                                                 THEN p_batch_id
                                                 ELSE c.last_changed_batch END,
                       state_hash         = n.state_hash
        WHEN NOT MATCHED THEN
            INSERT (encounter_key, facility, visit_number, mrn, patient_class, status,
                    admit_ts, discharge_ts, location, attending_npi, last_event_ts,
                    event_count, state_hash, first_loaded_batch, last_changed_batch)
            VALUES (n.encounter_key, n.facility, n.visit_number, n.mrn, n.patient_class,
                    n.status, n.admit_ts, n.discharge_ts, n.location, n.attending_npi,
                    n.last_event_ts, n.event_count, n.state_hash, p_batch_id, p_batch_id);

        ---------------------------------------------------------------------
        -- 7. Scorecard.
        ---------------------------------------------------------------------
        SELECT count(*) FILTER (WHERE disposition = 'QUARANTINED'),
               count(*) FILTER (WHERE disposition = 'DUP_CONTROL_ID'),
               count(*) FILTER (WHERE disposition = 'DUP_CONTENT')
          INTO v_quarantined, v_dup_ctl, v_dup_content
        FROM _incoming;

        SELECT count(*) INTO v_late
        FROM core.encounter_event e
        JOIN _incoming i ON i.source_system = e.source_system
                        AND i.msg_control_id = e.msg_control_id
                        AND i.disposition = 'APPLIED'
        WHERE e.is_late;

        UPDATE etl.batch_log
        SET status = 'SUCCEEDED', finished_at = clock_timestamp(),
            rows_landed = v_landed, rows_quarantined = v_quarantined,
            dup_control_id = v_dup_ctl, dup_content = v_dup_content,
            events_applied = v_applied, late_events = v_late,
            encounters_inserted = v_inserted, encounters_updated = v_updated,
            encounters_unchanged = v_unchanged
        WHERE batch_id = p_batch_id AND run_no = v_run_no;

    EXCEPTION WHEN OTHERS THEN
        -- Work above is rolled back to the start of the block; record why.
        UPDATE etl.batch_log
        SET status = 'FAILED', finished_at = clock_timestamp(), error_message = SQLERRM
        WHERE batch_id = p_batch_id AND run_no = v_run_no;
        RAISE WARNING 'batch % failed: %', p_batch_id, SQLERRM;
    END;
END;
$$;

-- Process every batch that still has undispositioned rows, oldest first,
-- committing after each so one bad day does not roll back the good ones.
CREATE OR REPLACE PROCEDURE etl.load_pending_batches()
LANGUAGE plpgsql AS $$
DECLARE
    b      date;
    status text;
BEGIN
    FOR b IN
        SELECT DISTINCT l.batch_id
        FROM landing.adt_event l
        WHERE NOT EXISTS (SELECT 1 FROM etl.event_disposition d
                          WHERE d.landing_id = l.landing_id)
        ORDER BY l.batch_id
    LOOP
        CALL etl.load_adt_batch(b);
        COMMIT;
        SELECT bl.status INTO status FROM etl.batch_log bl
        WHERE bl.batch_id = b ORDER BY bl.run_no DESC LIMIT 1;
        IF status = 'FAILED' THEN
            RAISE WARNING 'stopping at failed batch %', b;
            EXIT;
        END IF;
    END LOOP;
END;
$$;
