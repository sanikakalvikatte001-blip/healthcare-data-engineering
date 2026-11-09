-- Tiny assertion helpers (no extensions needed). A failed assert raises,
-- and psql -v ON_ERROR_STOP=1 turns that into a non-zero exit code.
DROP SCHEMA IF EXISTS t CASCADE;
CREATE SCHEMA t;

CREATE FUNCTION t.assert_eq(p_label text, p_actual anyelement, p_expected anyelement)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'FAIL  %: expected [%] got [%]', p_label, p_expected, p_actual;
    END IF;
    RAISE NOTICE 'PASS  %', p_label;
END;
$$;

CREATE FUNCTION t.assert_true(p_label text, p_condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL  %', p_label;
    END IF;
    RAISE NOTICE 'PASS  %', p_label;
END;
$$;

-- Insert one landing row with sensible defaults; keeps the scenarios readable.
CREATE FUNCTION t.land(
    p_batch date, p_ctl text, p_type text, p_visit text, p_event_ts timestamp,
    p_location text DEFAULT 'MED-4W', p_attending text DEFAULT '1111111111',
    p_class text DEFAULT 'I', p_admit_ts timestamp DEFAULT '2026-11-01 08:00',
    p_discharge_ts timestamp DEFAULT NULL, p_received_ts timestamp DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO landing.adt_event (batch_id, source_system, msg_control_id, event_type,
        event_ts, received_ts, facility, visit_number, mrn, patient_class, location,
        attending_npi, admit_ts, discharge_ts)
    VALUES (p_batch, 'EHR_ADT', p_ctl, p_type, p_event_ts,
            COALESCE(p_received_ts, p_batch + time '23:00'),
            'TST', p_visit, 'MRN-' || p_visit, p_class, p_location, p_attending,
            p_admit_ts, CASE WHEN p_type = 'A03' THEN COALESCE(p_discharge_ts, p_event_ts)
                             ELSE p_discharge_ts END);
$$;

-- Shorthand for reading back one encounter's current state.
CREATE FUNCTION t.enc(p_visit text) RETURNS core.encounter
LANGUAGE sql STABLE AS $$
    SELECT * FROM core.encounter WHERE encounter_key = 'TST|' || p_visit
$$;
