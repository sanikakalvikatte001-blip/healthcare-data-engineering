-- =============================================================================
-- 02_fold_encounter.sql
-- Re-derive one encounter's state by replaying its event log in EVENT-TIME
-- order (EVN-2), not arrival order. This is what makes the load order-proof:
-- a late A02 that arrives two days after the A03 is slotted back where it
-- happened, and the final state is the same no matter what order messages
-- arrived in.
-- =============================================================================

DROP TYPE IF EXISTS core.encounter_state CASCADE;
CREATE TYPE core.encounter_state AS (
    mrn            text,
    patient_class  text,
    status         text,
    admit_ts       timestamp,
    discharge_ts   timestamp,
    location       text,
    attending_npi  text,
    last_event_ts  timestamp,
    event_count    int,
    state_hash     text
);

-- Status to fall back to when the encounter has no admit/register event yet
-- (e.g. the A01 is still in flight but an A08 already arrived).
CREATE OR REPLACE FUNCTION core.default_status(p_patient_class text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_patient_class = 'I' THEN 'ADMITTED' ELSE 'REGISTERED' END
$$;

CREATE OR REPLACE FUNCTION core.fold_encounter(p_encounter_key text)
RETURNS core.encounter_state
LANGUAGE plpgsql STABLE AS $$
DECLARE
    s  core.encounter_state;
    e  core.encounter_event%ROWTYPE;
BEGIN
    s.event_count := 0;

    FOR e IN
        SELECT *
        FROM core.encounter_event
        WHERE encounter_key = p_encounter_key
        -- event time first; arrival time and event_id only break exact ties
        ORDER BY event_ts, received_ts, event_id
    LOOP
        s.event_count   := s.event_count + 1;
        s.last_event_ts := e.event_ts;

        -- Every ADT message carries the full PID/PV1 snapshot as of its
        -- event time, so a non-null value replaces what we had.
        s.mrn           := COALESCE(e.mrn,           s.mrn);
        s.patient_class := COALESCE(e.patient_class, s.patient_class);
        s.location      := COALESCE(e.location,      s.location);
        s.attending_npi := COALESCE(e.attending_npi, s.attending_npi);
        s.admit_ts      := COALESCE(e.admit_ts,      s.admit_ts);

        -- Status transitions (the trigger event decides these).
        CASE e.event_type
            WHEN 'A01' THEN                                   -- admit
                s.status := 'ADMITTED';
            WHEN 'A04' THEN                                   -- register outpatient
                s.status := 'REGISTERED';
            WHEN 'A03' THEN                                   -- discharge
                s.status       := 'DISCHARGED';
                s.discharge_ts := COALESCE(e.discharge_ts, e.event_ts);
            WHEN 'A13' THEN                                   -- cancel discharge
                s.status       := core.default_status(s.patient_class);
                s.discharge_ts := NULL;
            WHEN 'A11' THEN                                   -- cancel admit/visit
                s.status := 'CANCELLED';
            ELSE                                              -- A02 transfer, A08 update
                s.status := COALESCE(s.status, core.default_status(s.patient_class));
        END CASE;
    END LOOP;

    IF s.event_count = 0 THEN
        RETURN NULL;
    END IF;

    s.state_hash := md5(concat_ws('|',
        s.mrn, s.patient_class, s.status, s.admit_ts, s.discharge_ts,
        s.location, s.attending_npi));
    RETURN s;
END;
$$;
