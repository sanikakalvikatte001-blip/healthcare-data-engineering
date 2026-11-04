-- Source-to-mart reconciliation:
--   distinct (claim, line) in raw  - lines whose latest version is a void
--   = fact rows, and fact paid = paid of the latest non-void versions.
CREATE OR REPLACE VIEW tests.assert_reconciliation_raw_to_fact AS
WITH latest AS (
    SELECT claim_id, line_no, claim_freq_code, paid_amt
    FROM raw.claim_line
    QUALIFY row_number() OVER (PARTITION BY claim_id, line_no
                               ORDER BY received_ts DESC) = 1
),
expected AS (
    SELECT count(*) FILTER (WHERE claim_freq_code <> '8')            AS lines,
           sum(paid_amt) FILTER (WHERE claim_freq_code <> '8')      AS paid
    FROM latest
),
actual AS (
    SELECT count(*) AS lines, sum(paid_amt) AS paid FROM marts.fct_claim_line
)
SELECT e.lines AS expected_lines, a.lines AS actual_lines,
       e.paid  AS expected_paid,  a.paid  AS actual_paid
FROM expected e, actual a
WHERE e.lines <> a.lines OR e.paid <> a.paid;
