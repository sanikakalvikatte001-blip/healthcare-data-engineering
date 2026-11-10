"""End-to-end run over the generated data: hand-calculated scenario members + invariants.

PY2026 constants: normalization 1.045, coding-intensity adjustment 5.9%.
payment_raf = round(raw / 1.045 * 0.941, 3)
"""
import pytest
from pyspark.sql import functions as F

EXPECTED = {
    # member: (raw_raf, payment_raf, payment_hccs, interactions)
    # F70 0.437 + HCC37 0.166 + HCC224 0.432 + DIABETES_HF 0.112 (38 and 226 trumped)
    "M9001": (1.147, 1.033, [37, 224], ["DIABETES_HF"]),
    # M76 (birthday on Feb 1) 0.560 + HCC329 0.127; lab, voided and prior-year dx ignored
    "M9002": (0.687, 0.619, [329], []),
    # F64 0.300 + 17,48,93,155,280,326 (6.181) + D6 0.076; 18 and 23 trumped by 17; SNF bill ignored
    "M9003": (6.557, 5.904, [17, 48, 93, 155, 280, 326], []),
    # M85 0.765 + HCC222 0.512 (from the replacement claim) + HCC280 0.319 + HF_CHR_LUNG 0.078
    "M9004": (1.674, 1.507, [222, 280], ["HF_CHR_LUNG"]),
    # F67 (birthday is Feb 2) demographic only
    "M9005": (0.359, 0.323, [], []),
}


@pytest.mark.parametrize("member_id", sorted(EXPECTED))
def test_scenario_members(result, member_id):
    raw, pay, hccs, ixs = EXPECTED[member_id]
    r = result.member_raf.where(F.col("member_id") == member_id).first()
    assert r.raw_raf == pytest.approx(raw)
    assert r.payment_raf == pytest.approx(pay)
    assert r.payment_hccs == hccs
    assert r.interactions == ixs


def test_trumped_hccs_are_recorded_with_reason(result):
    rows = {(r.member_id, r.hcc): r.trumped_by for r in
            result.member_hcc.where("hcc_status = 'TRUMPED' AND member_id IN ('M9001','M9003')").collect()}
    assert rows == {("M9001", 38): [37], ("M9001", 226): [224], ("M9003", 18): [17], ("M9003", 23): [17, 18]}


def test_every_dx_line_gets_exactly_one_status(result):
    keys = ["claim_id", "claim_version", "dx_seq"]
    assert result.dx_audit.groupBy(keys).count().where("count > 1").count() == 0
    assert result.dx_audit.where("dx_status IS NULL").count() == 0


def test_every_enrolled_member_scored_once_and_no_one_else(result):
    raf = result.member_raf
    assert raf.count() == 405
    assert raf.select("member_id").distinct().count() == 405
    assert raf.where("member_id = 'M9999'").count() == 0
    assert raf.where("demographic_factor IS NULL OR payment_raf IS NULL").count() == 0


def test_no_member_is_paid_for_parent_and_child(result, ref):
    pay = result.member_hcc.where("hcc_status = 'PAYMENT'")
    clash = (pay.alias("p").join(ref.hierarchy.alias("h"), F.col("p.hcc") == F.col("h.parent_hcc"))
             .join(pay.alias("c"), (F.col("c.member_id") == F.col("p.member_id")) & (F.col("c.hcc") == F.col("h.child_hcc"))))
    assert clash.count() == 0


def test_raf_components_add_up(result):
    bad = result.member_raf.where(
        F.abs(F.col("demographic_factor") + F.col("disease_score") + F.col("interaction_score")
              + F.col("count_score") - F.col("raw_raf")) > 0.0015
    )
    assert bad.count() == 0
    assert result.member_raf.where("payment_raf < demographic_factor * 0.941 / 1.045 - 0.001").count() == 0
