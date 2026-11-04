-- Business scenarios planted on purpose in seeds/generate_synthetic_sources.sql.
-- Each row returned is a scenario that did NOT produce the expected history.
CREATE OR REPLACE VIEW tests.assert_scenarios_planted_in_seed AS
WITH v AS (
    SELECT npi, list(network_status ORDER BY effective_from) AS nets,
           list(roster_status  ORDER BY effective_from)      AS statuses,
           list(effective_from ORDER BY effective_from)      AS froms,
           count(*)                                          AS n
    FROM marts.dim_provider GROUP BY npi
),
checks AS (
    -- p=13: IN -> OUT (May-Jun) -> IN must stay 3 versions, not be merged
    SELECT 'A-B-A network flip kept as 3 versions' AS scenario,
           (SELECT nets FROM v WHERE npi = '1990102947') = ['IN','OUT','IN'] AS passed
    UNION ALL
    -- p=22: first Aug file said OUT, re-delivered file said IN -> no OUT ever
    SELECT 'Re-delivered file supersedes earlier load',
           NOT list_contains((SELECT nets FROM v WHERE npi = '1990174218'), 'OUT')
    UNION ALL
    -- p=3: only cosmetic name/case noise -> single version
    SELECT 'Cosmetic noise creates no version',
           (SELECT n FROM v WHERE npi = '1990023757') = 1
    UNION ALL
    -- p=17: missing from Sep file only -> one version, one gap-filled month
    SELECT 'One-month feed gap is carried forward',
           (SELECT n FROM v WHERE npi = '1990134623') = 1
       AND (SELECT gap_filled_months FROM intermediate.int_provider_versions
            WHERE npi = '1990134623') = 1
    UNION ALL
    -- p=50: last file Sep -> TERMED version from 2025-10-01
    SELECT 'Dropped provider is termed on first missing file',
           (SELECT statuses[-1] = 'INACTIVE' AND nets[-1] = 'TERMED'
                   AND froms[-1] = DATE '2025-10-01'
            FROM v WHERE npi = '1990395950')
    UNION ALL
    -- p=58: first file June -> inferred PRE_ROSTER version until 2025-05-31
    SELECT 'Late-credentialed provider gets PRE_ROSTER version',
           (SELECT effective_to = DATE '2025-05-31' AND network_status = 'NOT_ON_ROSTER'
            FROM marts.dim_provider
            WHERE npi = '1990459302' AND roster_status = 'PRE_ROSTER')
    UNION ALL
    -- replacement (freq 7) wins over original; void (freq 8) removes the line
    SELECT 'Replacement claim wins, voided claim removed',
           (SELECT count(*) FROM marts.fct_claim_line WHERE claim_id = 'CLM0000025'
                AND claim_freq_code = '7') > 0
       AND (SELECT count(*) FROM marts.fct_claim_line WHERE claim_id = 'CLM0000040') = 0
    UNION ALL
    -- NPIs never on a roster land on the Unknown member, not dropped
    SELECT 'Unknown NPI maps to provider_sk -1',
           (SELECT count(*) FROM marts.fct_claim_line
            WHERE rendering_npi LIKE '18800000%' AND provider_sk <> -1) = 0
       AND (SELECT count(*) FROM marts.fct_claim_line WHERE provider_sk = -1) > 0
)
SELECT scenario FROM checks WHERE passed IS DISTINCT FROM TRUE;
