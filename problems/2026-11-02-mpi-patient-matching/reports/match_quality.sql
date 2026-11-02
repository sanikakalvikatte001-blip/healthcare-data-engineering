-- =============================================================================
-- MPI run report: volumes, link decisions, review queue, and pairwise
-- precision / recall against the synthetic ground truth.
-- =============================================================================
\pset footer off

\echo '== Source records and enterprise IDs'
SELECT source_system,
       count(*)                        AS source_records,
       count(DISTINCT enterprise_id)   AS enterprise_ids
FROM mpi.source_patient
GROUP BY ROLLUP (source_system)
ORDER BY source_system NULLS LAST;

\echo '== Enterprise IDs vs. true people'
SELECT (SELECT count(*) FROM mpi.enterprise_patient WHERE status = 'ACTIVE') AS active_enterprise_ids,
       (SELECT count(*) FROM mpi.enterprise_patient WHERE status = 'MERGED') AS merged_enterprise_ids,
       (SELECT count(DISTINCT t.true_person_id)
          FROM stg.synthetic_truth t
          JOIN mpi.source_patient sp USING (source_system, source_patient_id)) AS true_people,
       (SELECT count(*) FROM mpi.registration_reject)                       AS rejected_rows;

\echo '== Link decisions by batch'
SELECT batch_id, event, count(*) AS n
FROM mpi.link_audit
GROUP BY batch_id, event
ORDER BY batch_id, event;

\echo '== Scored pairs by decision'
SELECT decision, count(*) AS pairs, min(total_weight) AS min_w, max(total_weight) AS max_w
FROM mpi.match_score
GROUP BY decision
ORDER BY decision;

\echo '== Review queue (and how many items are truly the same person)'
SELECT q.reason, count(*) AS items,
       count(*) FILTER (WHERE ta.true_person_id = tb.true_person_id) AS truly_same_person
FROM mpi.review_queue q
JOIN stg.synthetic_truth ta ON (ta.source_system, ta.source_patient_id) = (q.a_system, q.a_id)
JOIN stg.synthetic_truth tb ON (tb.source_system, tb.source_patient_id) = (q.b_system, q.b_id)
GROUP BY q.reason
ORDER BY q.reason;

\echo '== Pairwise accuracy of automatic linking (all pairs of loaded source records)'
SELECT * FROM mpi.v_pairwise_accuracy;

\echo '== Recall by data-quality issue: non-EHR records linked to the person''s EHR chart'
-- A record can carry several issues (e.g. nickname+no_ssn); it counts once per issue.
WITH rec AS (
    SELECT t.true_person_id, sp.enterprise_id, issue
    FROM stg.synthetic_truth t
    JOIN mpi.source_patient sp USING (source_system, source_patient_id)
    CROSS JOIN LATERAL unnest(string_to_array(t.scenario, '+')) issue
    WHERE t.source_system <> 'EHR_EPIC'
),
chart AS (             -- each person's original EHR chart
    SELECT t.true_person_id, sp.enterprise_id
    FROM stg.synthetic_truth t
    JOIN mpi.source_patient sp USING (source_system, source_patient_id)
    WHERE t.source_system = 'EHR_EPIC' AND t.scenario <> 'same_source_dup'
)
SELECT rec.issue,
       count(*)                                                     AS records,
       count(*) FILTER (WHERE rec.enterprise_id = chart.enterprise_id) AS linked,
       round(avg((rec.enterprise_id = chart.enterprise_id)::int), 3) AS recall
FROM rec JOIN chart USING (true_person_id)
GROUP BY rec.issue
ORDER BY records DESC, rec.issue;

\echo '== Hard negatives: twins and Jr/Sr pairs sharing an enterprise ID (must be 0)'
SELECT count(*) AS family_overlays FROM mpi.v_family_overlays;
