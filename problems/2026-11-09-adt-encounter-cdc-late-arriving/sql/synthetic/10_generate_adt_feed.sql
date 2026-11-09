-- =============================================================================
-- 10_generate_adt_feed.sql
-- Deterministic synthetic ADT feed (no real PHI). Builds:
--
--   synthetic.encounter_plan  what "really" happened to each encounter
--   synthetic.clean_event     the true event stream (one row per real event)
--   synthetic.expected_state  the correct final state, derived from the plan
--                             with plain CASE logic, independent of the fold
--   landing.adt_event         the clean stream as the interface engine would
--                             deliver it: late, redelivered, resent, plus junk
--
-- Randomness comes from md5 of a stable seed, so every run is identical.
-- :n_encounters is set by the caller (psql -v n_encounters=600).
-- =============================================================================

DROP SCHEMA IF EXISTS synthetic CASCADE;
CREATE SCHEMA synthetic;

-- Uniform [0,1) from a seed string. Deterministic across runs and machines.
CREATE FUNCTION synthetic.u(p_seed text) RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
    SELECT ('x' || substr(md5(p_seed), 1, 8))::bit(32)::bigint / 4294967296.0
$$;

-- Whole-minute offset helper.
CREATE FUNCTION synthetic.mins(p_lo_hours numeric, p_hi_hours numeric, p_seed text)
RETURNS interval LANGUAGE sql IMMUTABLE AS $$
    SELECT make_interval(mins => floor((p_lo_hours + (p_hi_hours - p_lo_hours)
                                        * synthetic.u(p_seed)) * 60)::int)
$$;

-- Extract window: the feed covers events up to (not including) this instant.
CREATE TABLE synthetic.params AS
SELECT timestamp '2026-11-01 00:00' AS window_start,
       timestamp '2026-11-04 00:00' AS window_end;

-- -----------------------------------------------------------------------------
-- 1. Encounter plan
-- -----------------------------------------------------------------------------
CREATE TABLE synthetic.encounter_plan AS
WITH base AS (
    SELECT g AS i,
           (ARRAY['NORTH','SOUTH','EAST'])[1 + floor(synthetic.u(g || ':fac') * 3)::int] AS facility,
           'V' || lpad(g::text, 7, '0')                                  AS visit_number,
           'MRN' || lpad((g * 7919 % 1000000)::text, 7, '0')             AS mrn,
           synthetic.u(g || ':class') < 0.75                             AS is_inpt,
           p.window_start + synthetic.mins(0, 48, g || ':admit')         AS admit_ts,
           floor(synthetic.u(g || ':loc0') * 5)::int                     AS loc_idx,
           floor(synthetic.u(g || ':loc1') * 4)::int                     AS loc_step,
           '1' || lpad(floor(synthetic.u(g || ':att0') * 1e9)::bigint::text, 9, '0') AS att0,
           '1' || lpad(floor(synthetic.u(g || ':att1') * 1e9)::bigint::text, 9, '0') AS att1,
           synthetic.u(g || ':cancel')  < 0.03 AS is_cancelled,
           synthetic.u(g || ':xfer')    < 0.40 AS roll_transfer,
           synthetic.u(g || ':a08')     < 0.30 AS roll_att_change,
           synthetic.u(g || ':a13')     < 0.06 AS roll_cancel_disch,
           p.window_end
    FROM generate_series(1, :n_encounters) g
    CROSS JOIN synthetic.params p
),
timed AS (
    SELECT b.*,
           CASE WHEN is_inpt
                THEN (ARRAY['MED-4W','SURG-3E','ICU-2','TELE-5','ORTHO-6'])[1 + loc_idx]
                ELSE (ARRAY['ED','CLINIC-A','INFUSION','ED','CLINIC-A'])[1 + loc_idx] END AS loc0,
           CASE WHEN is_inpt
                THEN (ARRAY['MED-4W','SURG-3E','ICU-2','TELE-5','ORTHO-6'])[1 + (loc_idx + 1 + loc_step) % 5] END AS loc1,
           is_inpt AND NOT is_cancelled AND roll_transfer          AS has_transfer,
           admit_ts + synthetic.mins(2, 24, i || ':xfer_t')         AS transfer_ts,
           NOT is_cancelled AND roll_att_change                    AS has_att_change,
           admit_ts + synthetic.mins(1, 6, i || ':a08_t')           AS a08_ts,
           admit_ts + CASE WHEN is_inpt
                           THEN synthetic.mins(30, 120, i || ':los')
                           ELSE synthetic.mins(2, 8, i || ':los') END AS disch_ts
    FROM base b
)
SELECT t.*,
       NOT is_cancelled AND disch_ts < window_end                   AS is_discharged,
       is_inpt AND NOT is_cancelled AND disch_ts < window_end
              AND roll_cancel_disch                                 AS has_cancel_disch
FROM timed t;

-- -----------------------------------------------------------------------------
-- 2. True event stream. Each message carries the PV1 snapshot as of its time.
-- -----------------------------------------------------------------------------
CREATE TABLE synthetic.clean_event AS
WITH ev AS (
    SELECT i, 1 AS seq, CASE WHEN is_inpt THEN 'A01' ELSE 'A04' END AS event_type,
           admit_ts AS event_ts
    FROM synthetic.encounter_plan
    UNION ALL
    SELECT i, 2, 'A11', admit_ts + interval '30 minutes'
    FROM synthetic.encounter_plan WHERE is_cancelled
    UNION ALL
    SELECT i, 3, 'A08', a08_ts       FROM synthetic.encounter_plan WHERE has_att_change
    UNION ALL
    SELECT i, 4, 'A02', transfer_ts  FROM synthetic.encounter_plan WHERE has_transfer
    UNION ALL   -- premature discharge, then the A13 that cancels it
    SELECT i, 5, 'A03', disch_ts - interval '6 hours' FROM synthetic.encounter_plan WHERE has_cancel_disch
    UNION ALL
    SELECT i, 6, 'A13', disch_ts - interval '5 hours' FROM synthetic.encounter_plan WHERE has_cancel_disch
    UNION ALL
    SELECT i, 7, 'A03', disch_ts     FROM synthetic.encounter_plan WHERE is_discharged
)
SELECT ev.i, ev.seq,
       'EHR_ADT'                                          AS source_system,
       'MSG' || lpad(ev.i::text, 6, '0') || '-' || ev.seq AS msg_control_id,
       ev.event_type, ev.event_ts,
       p.facility, p.visit_number, p.mrn,
       CASE WHEN p.is_inpt THEN 'I' ELSE 'O' END          AS patient_class,
       CASE WHEN p.has_transfer AND ev.event_ts >= p.transfer_ts THEN p.loc1 ELSE p.loc0 END AS location,
       CASE WHEN p.has_att_change AND ev.event_ts >= p.a08_ts THEN p.att1 ELSE p.att0 END   AS attending_npi,
       p.admit_ts,
       CASE WHEN ev.event_type = 'A03' THEN ev.event_ts END AS discharge_ts
FROM ev
JOIN synthetic.encounter_plan p USING (i);

-- -----------------------------------------------------------------------------
-- 3. Expected final state, straight from the plan (no event replay involved).
-- -----------------------------------------------------------------------------
CREATE TABLE synthetic.expected_state AS
SELECT facility || '|' || visit_number AS encounter_key,
       mrn,
       CASE WHEN is_inpt THEN 'I' ELSE 'O' END AS patient_class,
       CASE WHEN is_cancelled  THEN 'CANCELLED'
            WHEN is_discharged THEN 'DISCHARGED'
            WHEN is_inpt       THEN 'ADMITTED'
            ELSE 'REGISTERED' END               AS status,
       admit_ts,
       CASE WHEN is_discharged THEN disch_ts END AS discharge_ts,
       CASE WHEN has_transfer   THEN loc1 ELSE loc0 END AS location,
       CASE WHEN has_att_change THEN att1 ELSE att0 END AS attending_npi
FROM synthetic.encounter_plan;

-- -----------------------------------------------------------------------------
-- 4. Delivery: what the interface engine actually hands us.
--    ~8% of messages are held up 26-60h (queue backlog / downtime replay),
--    ~5% are redelivered with the same MSH-10, ~2% resent with a new MSH-10.
-- -----------------------------------------------------------------------------
CREATE TABLE synthetic.delivery AS
WITH first_delivery AS (
    SELECT c.*,
           'ORIGINAL' AS delivery_kind,
           c.event_ts + CASE WHEN synthetic.u(c.msg_control_id || ':late') < 0.08
                             THEN synthetic.mins(26, 60, c.msg_control_id || ':late_by')
                             ELSE synthetic.mins(0.02, 0.33, c.msg_control_id || ':lag') END
               AS received_ts
    FROM synthetic.clean_event c
)
SELECT * FROM first_delivery
UNION ALL   -- redelivery: same control id, later
SELECT f.i, f.seq, f.source_system, f.msg_control_id, f.event_type, f.event_ts,
       f.facility, f.visit_number, f.mrn, f.patient_class, f.location,
       f.attending_npi, f.admit_ts, f.discharge_ts,
       'REDELIVERY', f.received_ts + synthetic.mins(1, 30, f.msg_control_id || ':redel_t')
FROM first_delivery f
WHERE synthetic.u(f.msg_control_id || ':redel') < 0.05
UNION ALL   -- manual resend from the EHR: new control id, identical content
SELECT f.i, f.seq, f.source_system, f.msg_control_id || '-R', f.event_type, f.event_ts,
       f.facility, f.visit_number, f.mrn, f.patient_class, f.location,
       f.attending_npi, f.admit_ts, f.discharge_ts,
       'RESEND', f.received_ts + synthetic.mins(2, 10, f.msg_control_id || ':resend_t')
FROM first_delivery f
WHERE synthetic.u(f.msg_control_id || ':resend') < 0.02;

TRUNCATE landing.adt_event RESTART IDENTITY CASCADE;

INSERT INTO landing.adt_event (
    batch_id, source_system, msg_control_id, event_type, event_ts, received_ts,
    facility, visit_number, mrn, patient_class, location, attending_npi,
    admit_ts, discharge_ts)
SELECT d.received_ts::date, d.source_system, d.msg_control_id, d.event_type,
       d.event_ts, d.received_ts, d.facility, d.visit_number, d.mrn,
       d.patient_class, d.location, d.attending_npi, d.admit_ts, d.discharge_ts
FROM synthetic.delivery d
ORDER BY d.received_ts, d.msg_control_id;

-- Structurally bad messages that must be quarantined, never applied.
INSERT INTO landing.adt_event (
    batch_id, source_system, msg_control_id, event_type, event_ts, received_ts,
    facility, visit_number, mrn, patient_class, location, attending_npi,
    admit_ts, discharge_ts)
VALUES
 -- PV1-19 missing (registration clerk saved without a visit number)
 ('2026-11-01','EHR_ADT','BAD-0001','A01','2026-11-01 08:00','2026-11-01 08:05','NORTH',NULL,'MRN0000001','I','MED-4W','1000000001','2026-11-01 08:00',NULL),
 ('2026-11-02','EHR_ADT','BAD-0002','A08','2026-11-02 09:00','2026-11-02 09:02','SOUTH',NULL,'MRN0000002','I','ICU-2','1000000002','2026-11-02 07:00',NULL),
 ('2026-11-03','EHR_ADT',NULL,      'A02','2026-11-03 10:00','2026-11-03 10:01','EAST','V0000003','MRN0000003','I','TELE-5','1000000003','2026-11-03 06:00',NULL),
 -- A28 (add person) is a patient-level event, not an encounter event
 ('2026-11-01','EHR_ADT','BAD-0004','A28','2026-11-01 11:00','2026-11-01 11:01','NORTH','V9000004','MRN0000004','O','ED','1000000004',NULL,NULL),
 ('2026-11-03','EHR_ADT','BAD-0005','A31','2026-11-03 12:00','2026-11-03 12:01','SOUTH','V9000005','MRN0000005','O','ED','1000000005',NULL,NULL),
 -- discharge stamped before admit
 ('2026-11-02','EHR_ADT','BAD-0006','A03','2026-11-02 14:00','2026-11-02 14:03','EAST','V9000006','MRN0000006','I','SURG-3E','1000000006','2026-11-02 16:00','2026-11-02 14:00'),
 ('2026-11-03','EHR_ADT','BAD-0007','A03','2026-11-03 15:00','2026-11-03 15:02','NORTH','V9000007','MRN0000007','I','MED-4W','1000000007','2026-11-03 18:00','2026-11-03 15:00'),
 -- sender clock skew: event "happened" an hour after we received it
 ('2026-11-02','EHR_ADT','BAD-0008','A08','2026-11-02 18:00','2026-11-02 17:00','SOUTH','V9000008','MRN0000008','O','CLINIC-A','1000000008','2026-11-02 16:30',NULL);
