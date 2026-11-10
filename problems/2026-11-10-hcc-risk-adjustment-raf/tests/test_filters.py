"""Unit tests for claim versioning, source eligibility and ICD-10 handling."""
from datetime import date

from pyspark.sql import functions as F

from hcc_raf.config import CLAIM_DX_SCHEMA, CLAIM_HEADER_SCHEMA, MEMBER_SCHEMA
from hcc_raf.filters import build_dx_audit, classify_source, normalize_icd10, resolve_claim_versions

D = date(2025, 6, 1)


def hdr(claim_id, version=1, freq="1", member="M1", claim_type="PROF", bill_type=None,
        cpt="99214", specialty="FAMILY_PRACTICE", dos=D, status="PAID"):
    return (claim_id, version, freq, member, claim_type, bill_type, cpt, specialty, dos, dos, status)


def statuses(spark, cfg, ref, headers, dx):
    members = spark.createDataFrame([("M1", "F", date(1950, 1, 1))], MEMBER_SCHEMA)
    h = spark.createDataFrame(headers, CLAIM_HEADER_SCHEMA)
    d = spark.createDataFrame(dx, CLAIM_DX_SCHEMA)
    rows = build_dx_audit(d, h, members, ref.dx_to_hcc, cfg).collect()
    return {(r.claim_id, r.claim_version, r.dx_seq): (r.dx_status, r.hcc) for r in rows}


def test_latest_version_wins_and_void_kills_all_versions(spark):
    h = spark.createDataFrame(
        [hdr("A", 1), hdr("A", 2, "7"), hdr("B", 1), hdr("B", 2, "7"), hdr("B", 3, "8"), hdr("C", 1)],
        CLAIM_HEADER_SCHEMA,
    )
    got = {(r.claim_id, r.claim_version): r.version_status for r in resolve_claim_versions(h).collect()}
    assert got == {
        ("A", 1): "SUPERSEDED", ("A", 2): "CURRENT",
        ("B", 1): "VOIDED", ("B", 2): "VOIDED", ("B", 3): "VOIDED",
        ("C", 1): "CURRENT",
    }


def test_source_eligibility_rules(spark, cfg):
    rows = [
        hdr("ok_office"),
        hdr("lab", cpt="80053", specialty="CLINICAL_LAB"),
        hdr("rad_with_em_code", cpt="99214", specialty="DIAGNOSTIC_RADIOLOGY"),
        hdr("not_face_to_face", cpt="36415"),
        hdr("denied", status="DENIED"),
        hdr("prior_year", dos=date(2024, 12, 31)),
        hdr("inpatient", claim_type="INST", bill_type="111", cpt=None, specialty=None),
        hdr("hopd_visit", claim_type="INST", bill_type="131", cpt="99213", specialty=None),
        hdr("hopd_xray", claim_type="INST", bill_type="131", cpt="71046", specialty=None),
        hdr("snf", claim_type="INST", bill_type="211", cpt=None, specialty=None),
        hdr("inst_no_bill_type", claim_type="INST", bill_type=None, cpt="99213", specialty=None),
    ]
    out = classify_source(cfg)(spark.createDataFrame(rows, CLAIM_HEADER_SCHEMA))
    got = {r.claim_id: r.source_exclusion for r in out.collect()}
    assert got == {
        "ok_office": None,
        "lab": "INELIGIBLE_PROVIDER_TYPE",
        "rad_with_em_code": "INELIGIBLE_PROVIDER_TYPE",
        "not_face_to_face": "INELIGIBLE_SERVICE",
        "denied": "CLAIM_DENIED",
        "prior_year": "DOS_OUT_OF_WINDOW",
        "inpatient": None,
        "hopd_visit": None,
        "hopd_xray": "INELIGIBLE_SERVICE",
        "snf": "INELIGIBLE_BILL_TYPE",
        "inst_no_bill_type": "INELIGIBLE_BILL_TYPE",
    }


def test_dos_window_is_inclusive(spark, cfg):
    rows = [hdr("first", dos=date(2025, 1, 1)), hdr("last", dos=date(2025, 12, 31)), hdr("after", dos=date(2026, 1, 1))]
    got = {r.claim_id: r.source_exclusion for r in classify_source(cfg)(spark.createDataFrame(rows, CLAIM_HEADER_SCHEMA)).collect()}
    assert got == {"first": None, "last": None, "after": "DOS_OUT_OF_WINDOW"}


def test_icd10_normalization(spark):
    df = spark.createDataFrame([(" e11.22 ",), ("N18.30",), ("I10",)], "icd10_raw STRING")
    assert [r[0] for r in df.select(normalize_icd10()).collect()] == ["E1122", "N1830", "I10"]


def test_dx_status_precedence_and_mapping(spark, cfg, ref):
    headers = [hdr("A"), hdr("V", 1), hdr("V", 2, "8"), hdr("X", member="M_NOT_ENROLLED"), hdr("D", status="DENIED")]
    dx = [
        ("A", 1, 1, "E11.22"),   # maps to HCC 37
        ("A", 1, 2, "I10"),      # valid, no HCC
        ("A", 1, 3, "E1#9"),     # malformed
        ("A", 1, 4, None),       # blank
        ("V", 1, 1, "N18.4"),    # claim later voided
        ("X", 1, 1, "J44.9"),    # unknown member
        ("D", 1, 1, "invalid"),  # denial outranks the bad code
        ("Z", 1, 1, "I50.9"),    # header never arrived
    ]
    assert statuses(spark, cfg, ref, headers, dx) == {
        ("A", 1, 1): ("ACCEPTED", 37),
        ("A", 1, 2): ("NO_HCC_MAPPING", None),
        ("A", 1, 3): ("INVALID_ICD10_FORMAT", None),
        ("A", 1, 4): ("INVALID_ICD10_FORMAT", None),
        ("V", 1, 1): ("CLAIM_VOIDED", None),
        ("X", 1, 1): ("UNKNOWN_MEMBER", None),
        ("D", 1, 1): ("CLAIM_DENIED", None),
        ("Z", 1, 1): ("ORPHAN_DX_NO_HEADER", None),
    }
