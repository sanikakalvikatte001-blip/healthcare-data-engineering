-- =============================================================================
-- V006  Evaluation views (synthetic data only)
--
-- Pairwise precision / recall: over every pair of loaded source records,
-- compare "same enterprise ID" (prediction) with "same true person" (truth).
--   precision = of the pairs we linked, how many are truly one person
--   recall    = of the true same-person pairs, how many we linked
-- In an MPI a false link (overlay) is far worse than a missed link (duplicate),
-- so precision is the number that must stay at 1.000.
-- =============================================================================

CREATE VIEW mpi.v_pairwise_accuracy AS
WITH r AS (
    SELECT sp.source_system, sp.source_patient_id, sp.enterprise_id, t.true_person_id
    FROM mpi.source_patient sp
    JOIN stg.synthetic_truth t USING (source_system, source_patient_id)
),
pairs AS (
    SELECT (a.enterprise_id  = b.enterprise_id)  AS predicted_same,
           (a.true_person_id = b.true_person_id) AS truly_same
    FROM r a
    JOIN r b ON (a.source_system, a.source_patient_id) < (b.source_system, b.source_patient_id)
    -- only pairs that could be the same in either view need counting
    WHERE a.enterprise_id = b.enterprise_id OR a.true_person_id = b.true_person_id
),
c AS (
    SELECT count(*) FILTER (WHERE predicted_same AND truly_same)     AS true_links,
           count(*) FILTER (WHERE predicted_same AND NOT truly_same) AS false_links,
           count(*) FILTER (WHERE NOT predicted_same AND truly_same) AS missed_links
    FROM pairs
)
SELECT true_links, false_links, missed_links,
       round(true_links::numeric / nullif(true_links + false_links, 0), 4)  AS precision,
       round(true_links::numeric / nullif(true_links + missed_links, 0), 4) AS recall
FROM c;

-- Family hard negatives (twins, Jr/Sr): any record of the two people sharing
-- an enterprise ID is an overlay.
CREATE VIEW mpi.v_family_overlays AS
SELECT DISTINCT kid.person_id AS person_id, ref.person_id AS relative_id, kid.family_role
FROM stg.synthetic_person kid
JOIN stg.synthetic_person ref ON ref.person_id = NULLIF(split_part(kid.family_role, '_of_', 2), '')::int
JOIN stg.synthetic_truth ta ON ta.true_person_id = kid.person_id
JOIN stg.synthetic_truth tb ON tb.true_person_id = ref.person_id
JOIN mpi.source_patient a ON (a.source_system, a.source_patient_id) = (ta.source_system, ta.source_patient_id)
JOIN mpi.source_patient b ON (b.source_system, b.source_patient_id) = (tb.source_system, tb.source_patient_id)
WHERE kid.family_role <> 'independent'
  AND a.enterprise_id = b.enterprise_id;
