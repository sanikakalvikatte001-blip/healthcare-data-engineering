"""Unit tests for hierarchies, interactions, count variables, age and RAF math."""
from datetime import date

import pytest
from pyspark.sql import functions as F

from hcc_raf.config import MEMBER_SCHEMA, validate_reference_tables
from hcc_raf.hierarchy import apply_hierarchies
from hcc_raf.scoring import age_as_of, score_members


def hcc_frame(spark, rows):
    return spark.createDataFrame(rows, "member_id STRING, hcc INT")


def test_hierarchy_keeps_only_most_severe(spark, ref):
    hccs = hcc_frame(spark, [
        ("M1", 326), ("M1", 327), ("M1", 329),   # CKD 5 trumps 4 and 3
        ("M2", 18), ("M2", 23),                  # bone mets trumps breast cancer
        ("M3", 17), ("M3", 23),                  # skips 18: transitivity still applies
        ("M4", 38), ("M4", 280),                 # unrelated families both pay
    ])
    got = {(r.member_id, r.hcc): (r.hcc_status, r.trumped_by)
           for r in apply_hierarchies(hccs, ref.hierarchy).collect()}
    assert got == {
        ("M1", 326): ("PAYMENT", None), ("M1", 327): ("TRUMPED", [326]), ("M1", 329): ("TRUMPED", [326, 327]),
        ("M2", 18): ("PAYMENT", None), ("M2", 23): ("TRUMPED", [18]),
        ("M3", 17): ("PAYMENT", None), ("M3", 23): ("TRUMPED", [17]),
        ("M4", 38): ("PAYMENT", None), ("M4", 280): ("PAYMENT", None),
    }


@pytest.mark.parametrize("dob, expected", [
    (date(1956, 2, 1), 70),    # birthday on the as-of date counts
    (date(1956, 2, 2), 69),    # one day later does not
    (date(1956, 1, 31), 70),
    (date(1960, 2, 29), 65),   # leap-day birth
])
def test_age_as_of_feb_1(spark, dob, expected):
    df = spark.createDataFrame([(dob,)], "birth_date DATE")
    assert df.select(age_as_of("birth_date", date(2026, 2, 1))).first()[0] == expected


def test_raf_math_with_interaction_and_count_variable(spark, ref, cfg):
    members = spark.createDataFrame(
        [("M1", "M", date(1955, 6, 1)), ("M2", "F", date(1940, 6, 1)), ("M3", "F", date(1958, 6, 1))],
        MEMBER_SCHEMA,
    )
    payment = [("M1", h) for h in (38, 226)] + [("M2", h) for h in (17, 48, 93, 155, 280)]
    hcc_table = hcc_frame(spark, payment).withColumn("hcc_status", F.lit("PAYMENT"))
    got = {r.member_id: r for r in score_members(members, hcc_table, ref, cfg).collect()}

    # M1: male 70 (0.468) + HCC38 0.166 + HCC226 0.360 + DIABETES_HF 0.112 = 1.106
    assert got["M1"].raw_raf == pytest.approx(1.106)
    assert got["M1"].interactions == ["DIABETES_HF"]
    assert got["M1"].payment_raf == pytest.approx(round(1.106 / 1.045 * 0.941, 3))

    # M2: female 85 (0.698) + 4.209 + 0.186 + 0.353 + 0.299 + 0.319 + D5 0.056 = 6.120
    assert got["M2"].count_variable == "D5"
    assert got["M2"].raw_raf == pytest.approx(6.120)

    # M3: no HCCs -> demographic only, female 67
    assert got["M3"].payment_hcc_count == 0
    assert got["M3"].raw_raf == pytest.approx(0.359)


def test_validation_rejects_non_transitive_hierarchy(spark, ref):
    broken = ref.hierarchy.where("NOT (parent_hcc = 326 AND child_hcc = 329)")
    with pytest.raises(ValueError, match="transitively closed"):
        validate_reference_tables(ref.__class__(**{**ref.__dict__, "hierarchy": broken}))


def test_validation_rejects_hcc_without_coefficient(spark, ref):
    extra = ref.dx_to_hcc.unionByName(spark.createDataFrame([("Z9999", 999, "made up")], ref.dx_to_hcc.schema))
    with pytest.raises(ValueError, match="no coefficient"):
        validate_reference_tables(ref.__class__(**{**ref.__dict__, "dx_to_hcc": extra}))
