-- Blood-pressure selection rules, re-derived independently from the fact table.
INSERT INTO test_result
SELECT 'bp: representative date never comes from ED/inpatient or outside the MY', count(*)
FROM int.representative_bp r
WHERE NOT EXISTS (
    SELECT 1 FROM mart.fct_bp_reading f
    WHERE f.member_id = r.member_id AND f.reading_date = r.reading_date AND f.counts_for_cbp
);

INSERT INTO test_result
SELECT 'bp: representative date is the latest countable date with both components', count(*)
FROM int.representative_bp r
JOIN (
    SELECT member_id, max(reading_date) AS latest
    FROM (SELECT member_id, reading_date
          FROM mart.fct_bp_reading WHERE counts_for_cbp
          GROUP BY ALL
          HAVING count(systolic) > 0 AND count(diastolic) > 0)
    GROUP BY member_id
) x USING (member_id)
WHERE r.reading_date <> x.latest;

INSERT INTO test_result
SELECT 'bp: representative values are the same-day minimums', count(*)
FROM int.representative_bp r
JOIN (SELECT member_id, reading_date, min(systolic) s, min(diastolic) d
      FROM mart.fct_bp_reading WHERE counts_for_cbp GROUP BY ALL) m
  USING (member_id, reading_date)
WHERE r.systolic <> m.s OR r.diastolic <> m.d;

INSERT INTO test_result
SELECT 'bp: every valid reading passes range and systolic > diastolic checks', count(*)
FROM mart.fct_bp_reading
WHERE source_system = 'EHR'
  AND NOT (systolic BETWEEN 60 AND 300 AND diastolic BETWEEN 30 AND 200 AND systolic > diastolic);
