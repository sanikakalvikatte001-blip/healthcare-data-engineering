-- =============================================================================
-- V005  mpi.process_batch - the MPI load for one batch of registrations
--
--   1. reject rows that cannot be matched (no name, invalid DOB)
--   2. MERGE the latest version of each source record into mpi.source_patient
--   3. rebuild blocking keys for new / changed records
--   4. score every candidate pair (set-based)
--   5. assign enterprise IDs record by record (procedural: each decision
--      depends on the links made just before it), merging IDs when a new
--      record proves two existing IDs are one person
--   6. queue uncertain pairs for a data steward
--
-- Idempotent: re-running a batch changes nothing.
-- Identity is sticky: a resend with new demographics updates the record but
-- does not move it to another enterprise ID (that is a steward decision).
-- =============================================================================

CREATE PROCEDURE mpi.process_batch(p_batch_id text)
LANGUAGE plpgsql AS $$
DECLARE
    v_auto_link  numeric;
    v_review     numeric;
    rec          record;
    v_targets    bigint[];
    v_best       numeric;
    v_survivor   bigint;
    v_other      bigint;
    n_new        int := 0;
    n_link       int := 0;
    n_merge      int := 0;
    n_rows       int;
BEGIN
    SELECT value INTO STRICT v_auto_link FROM mpi.match_threshold WHERE name = 'AUTO_LINK';
    SELECT value INTO STRICT v_review    FROM mpi.match_threshold WHERE name = 'REVIEW';

    -- 1. Rejects -----------------------------------------------------------
    INSERT INTO mpi.registration_reject (load_id, batch_id, reason)
    SELECT s.load_id, s.batch_id,
           CASE WHEN util.norm_name(s.first_name) IS NULL OR util.norm_name(s.last_name) IS NULL
                THEN 'MISSING_NAME' ELSE 'INVALID_BIRTH_DATE' END
    FROM stg.patient_registration s
    WHERE s.batch_id = p_batch_id
      AND (util.norm_name(s.first_name) IS NULL
           OR util.norm_name(s.last_name) IS NULL
           OR util.parse_dob(s.birth_date_raw) IS NULL)
    ON CONFLICT (load_id) DO NOTHING;

    -- 2. Upsert normalized source records (latest message per MRN wins) -----
    MERGE INTO mpi.source_patient t
    USING (
        SELECT n.*,
               md5(concat_ws('|', n.first_name, n.last_name, n.birth_date, n.sex, n.ssn,
                             n.phone, n.address_norm, n.zip5)) AS record_hash
        FROM (
            SELECT DISTINCT ON (s.source_system, s.source_patient_id)
                   s.source_system,
                   s.source_patient_id,
                   util.norm_name(s.first_name)    AS first_name,
                   util.canon_first(s.first_name)  AS first_name_canon,
                   util.norm_name(s.last_name)     AS last_name,
                   util.parse_dob(s.birth_date_raw) AS birth_date,
                   util.norm_sex(s.sex_raw)        AS sex,
                   util.norm_ssn(s.ssn_raw)        AS ssn,
                   util.norm_phone(s.phone_raw)    AS phone,
                   util.norm_address(s.address_line) AS address_norm,
                   util.norm_zip(s.zip_raw)        AS zip5
            FROM stg.patient_registration s
            WHERE s.batch_id = p_batch_id
              AND NOT EXISTS (SELECT 1 FROM mpi.registration_reject r WHERE r.load_id = s.load_id)
            ORDER BY s.source_system, s.source_patient_id, s.received_at DESC, s.load_id DESC
        ) n
    ) src
    ON  t.source_system = src.source_system
    AND t.source_patient_id = src.source_patient_id
    WHEN MATCHED AND t.record_hash <> src.record_hash THEN UPDATE SET
        first_name = src.first_name, first_name_canon = src.first_name_canon,
        last_name = src.last_name, birth_date = src.birth_date, sex = src.sex,
        ssn = src.ssn, phone = src.phone, address_norm = src.address_norm,
        zip5 = src.zip5, record_hash = src.record_hash, last_batch = p_batch_id
    WHEN NOT MATCHED THEN INSERT
        (source_system, source_patient_id, first_name, first_name_canon, last_name,
         birth_date, sex, ssn, phone, address_norm, zip5, record_hash,
         first_batch, last_batch, needs_matching)
    VALUES
        (src.source_system, src.source_patient_id, src.first_name, src.first_name_canon,
         src.last_name, src.birth_date, src.sex, src.ssn, src.phone, src.address_norm,
         src.zip5, src.record_hash, p_batch_id, p_batch_id, true);

    -- 3. Blocking keys for records touched by this batch --------------------
    DELETE FROM mpi.block_key k
    USING mpi.source_patient sp
    WHERE sp.last_batch = p_batch_id
      AND k.source_system = sp.source_system
      AND k.source_patient_id = sp.source_patient_id;

    INSERT INTO mpi.block_key (source_system, source_patient_id, block_key)
    SELECT DISTINCT sp.source_system, sp.source_patient_id, k
    FROM mpi.source_patient sp
    CROSS JOIN LATERAL mpi.block_keys(sp) k
    WHERE sp.last_batch = p_batch_id;

    -- 4. Score candidate pairs: each unmatched record vs. everything in its
    --    blocks. Pairs of two unmatched records are scored once (a < b).
    INSERT INTO mpi.match_score
    SELECT p_batch_id, a.source_system, a.source_patient_id, b.source_system, b.source_patient_id,
           s.last_cmp, s.first_cmp, s.dob_cmp, s.ssn_cmp, s.sex_cmp, s.phone_cmp, s.zip_cmp, s.addr_cmp,
           s.total_weight,
           CASE WHEN s.total_weight >= v_auto_link THEN 'AUTO_LINK'
                WHEN s.total_weight >= v_review    THEN 'REVIEW'
                ELSE 'NON_MATCH' END
    FROM (
        SELECT DISTINCT ka.source_system AS a_sys, ka.source_patient_id AS a_id,
                        kb.source_system AS b_sys, kb.source_patient_id AS b_id
        FROM mpi.block_key ka
        JOIN mpi.block_key kb
          ON kb.block_key = ka.block_key
         AND (kb.source_system, kb.source_patient_id) <> (ka.source_system, ka.source_patient_id)
        JOIN mpi.source_patient pa
          ON (pa.source_system, pa.source_patient_id) = (ka.source_system, ka.source_patient_id)
        JOIN mpi.source_patient pb
          ON (pb.source_system, pb.source_patient_id) = (kb.source_system, kb.source_patient_id)
        WHERE pa.needs_matching
          AND (NOT pb.needs_matching
               OR (pa.source_system, pa.source_patient_id) < (pb.source_system, pb.source_patient_id))
    ) cand
    JOIN mpi.source_patient a ON (a.source_system, a.source_patient_id) = (cand.a_sys, cand.a_id)
    JOIN mpi.source_patient b ON (b.source_system, b.source_patient_id) = (cand.b_sys, cand.b_id)
    CROSS JOIN LATERAL mpi.score_pair(a, b) s
    ON CONFLICT DO NOTHING;

    -- 5. Assign enterprise IDs, one record at a time ------------------------
    FOR rec IN
        SELECT source_system, source_patient_id
        FROM mpi.source_patient
        WHERE needs_matching
        ORDER BY source_system, source_patient_id
    LOOP
        -- Auto-link partners that already carry an enterprise ID. Partners
        -- from the SAME source are excluded: two MRNs in one EHR for one
        -- person is a duplicate chart, which HIM must review, not auto-link.
        SELECT array_agg(DISTINCT p.enterprise_id ORDER BY p.enterprise_id),
               max(ms.total_weight)
        INTO   v_targets, v_best
        FROM mpi.match_score ms
        JOIN mpi.source_patient p
          ON (p.source_system, p.source_patient_id) =
             CASE WHEN (ms.a_system, ms.a_id) = (rec.source_system, rec.source_patient_id)
                  THEN (ms.b_system, ms.b_id) ELSE (ms.a_system, ms.a_id) END
        WHERE ms.decision = 'AUTO_LINK'
          AND ((ms.a_system, ms.a_id) = (rec.source_system, rec.source_patient_id)
            OR (ms.b_system, ms.b_id) = (rec.source_system, rec.source_patient_id))
          AND p.source_system <> rec.source_system
          AND p.enterprise_id IS NOT NULL;

        IF v_targets IS NULL THEN
            INSERT INTO mpi.enterprise_patient (created_batch) VALUES (p_batch_id)
            RETURNING enterprise_id INTO v_survivor;
            INSERT INTO mpi.link_audit (batch_id, event, source_system, source_patient_id, enterprise_id)
            VALUES (p_batch_id, 'NEW_ENTERPRISE_ID', rec.source_system, rec.source_patient_id, v_survivor);
            n_new := n_new + 1;
        ELSE
            v_survivor := v_targets[1];          -- oldest ID survives
            INSERT INTO mpi.link_audit (batch_id, event, source_system, source_patient_id, enterprise_id, total_weight)
            VALUES (p_batch_id, 'LINK', rec.source_system, rec.source_patient_id, v_survivor, v_best);
            n_link := n_link + 1;

            -- The new record bridges several IDs: they are one person. Merge -
            -- unless both IDs already hold a record from the same source
            -- (e.g. two EHR MRNs). Auto-merging would silently collapse a
            -- duplicate chart, so that case goes to a steward instead.
            FOREACH v_other IN ARRAY v_targets[2:] LOOP
                IF EXISTS (SELECT 1
                             FROM mpi.source_patient x
                             JOIN mpi.source_patient y ON y.source_system = x.source_system
                            WHERE x.enterprise_id = v_survivor
                              AND y.enterprise_id = v_other) THEN
                    INSERT INTO mpi.review_queue (batch_id, a_system, a_id, b_system, b_id, total_weight, reason)
                    SELECT p_batch_id, rec.source_system, rec.source_patient_id,
                           p.source_system, p.source_patient_id, v_best, 'MERGE_BLOCKED_SAME_SOURCE'
                    FROM mpi.source_patient p
                    WHERE p.enterprise_id = v_other
                    ORDER BY p.source_system, p.source_patient_id
                    LIMIT 1
                    ON CONFLICT DO NOTHING;
                    CONTINUE;
                END IF;

                UPDATE mpi.enterprise_patient
                   SET status = 'MERGED', merged_into = v_survivor, merged_batch = p_batch_id
                 WHERE enterprise_id = v_other;
                UPDATE mpi.enterprise_patient SET merged_into = v_survivor   -- keep chains flat
                 WHERE merged_into = v_other;
                UPDATE mpi.source_patient SET enterprise_id = v_survivor
                 WHERE enterprise_id = v_other;
                INSERT INTO mpi.link_audit (batch_id, event, source_system, source_patient_id,
                                            enterprise_id, other_enterprise_id, total_weight)
                VALUES (p_batch_id, 'MERGE', rec.source_system, rec.source_patient_id,
                        v_survivor, v_other, v_best);
                n_merge := n_merge + 1;
            END LOOP;
        END IF;

        UPDATE mpi.source_patient
           SET enterprise_id = v_survivor, needs_matching = false
         WHERE (source_system, source_patient_id) = (rec.source_system, rec.source_patient_id);
    END LOOP;

    -- 6. Review queue: uncertain pairs, and confident same-source duplicates,
    --    that still sit on different enterprise IDs.
    INSERT INTO mpi.review_queue (batch_id, a_system, a_id, b_system, b_id, total_weight, reason)
    SELECT ms.batch_id, ms.a_system, ms.a_id, ms.b_system, ms.b_id, ms.total_weight,
           CASE WHEN ms.decision = 'AUTO_LINK' THEN 'SAME_SOURCE_DUPLICATE'
                ELSE 'SCORE_IN_REVIEW_BAND' END
    FROM mpi.match_score ms
    JOIN mpi.source_patient a ON (a.source_system, a.source_patient_id) = (ms.a_system, ms.a_id)
    JOIN mpi.source_patient b ON (b.source_system, b.source_patient_id) = (ms.b_system, ms.b_id)
    WHERE ms.batch_id = p_batch_id
      AND a.enterprise_id <> b.enterprise_id
      AND (ms.decision = 'REVIEW' OR (ms.decision = 'AUTO_LINK' AND ms.a_system = ms.b_system))
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n_rows = ROW_COUNT;

    RAISE NOTICE 'batch %: new IDs %, links %, merges %, review items %',
                 p_batch_id, n_new, n_link, n_merge, n_rows;
END $$;
