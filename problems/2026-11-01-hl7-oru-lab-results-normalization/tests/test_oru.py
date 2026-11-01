from zoneinfo import ZoneInfo

import pytest

from oru_feed import oru
from oru_feed.hl7 import parse_message


def make(obx_lines, facility="NWLAB", pid="PID|1||M1^^^NWHS^MR", msh7="202610291000-0400",
         mtype="ORU^R01", obr7="202610290800-0400"):
    segs = [f"MSH|^~\\&|LIS|{facility}|HDE_INGEST|HDE|{msh7}||{mtype}|C1|P|2.5.1", pid,
            f"OBR|1|PL1|ACC1|BMP^BMP^L|||{obr7}"] + obx_lines
    return parse_message("\r".join(segs))


def test_timestamp_offset_and_local_zone():
    assert oru.parse_hl7_ts("202610290800-0400", ZoneInfo("UTC")).hour == 12
    # No offset: lab zone applies, including DST (CDT in Oct, CST in Dec)
    chi = ZoneInfo("America/Chicago")
    assert oru.parse_hl7_ts("202610290800", chi).hour == 13
    assert oru.parse_hl7_ts("202612010800", chi).hour == 14
    with pytest.raises(ValueError):
        oru.parse_hl7_ts("2026-10-29", chi)


def test_loinc_coded_numeric(ref):
    rows, rejects = oru.map_oru(make(["OBX|1|NM|2345-7^Glucose^LN||98|mg/dL|70-99||||F"]), ref)
    assert not rejects
    r = rows[0]
    assert (r.loinc, r.value_numeric, r.unit, r.mrn, r.accession_number) == ("2345-7", 98.0, "mg/dL", "M1", "ACC1")
    assert r.observed_at_utc == "2026-10-29T12:00:00Z"   # fell back to OBR-7


def test_local_code_crosswalk_and_si_conversion(ref):
    msg = make(["OBX|1|NM|GLU^Glucose^L||5.5|mmol/L||||||F",
                "OBX|2|NM|A1C^HbA1c^L||53|mmol/mol||||||F",
                "OBX|3|NM|CREAT^Creat^L||88.4|µmol/L||||||F"], facility="CEDAR")
    rows, rejects = oru.map_oru(msg, ref)
    assert not rejects
    vals = {r.loinc: (r.value_numeric, r.unit) for r in rows}
    assert vals["2345-7"] == (pytest.approx(99.088), "mg/dL")
    assert vals["4548-4"] == (pytest.approx(7.0, abs=0.01), "%")     # IFCC 53 mmol/mol ~ NGSP 7.0 %
    assert vals["2160-0"] == (pytest.approx(1.0, abs=1e-3), "mg/dL")


def test_alternate_triplet_loinc(ref):
    rows, _ = oru.map_oru(make(["OBX|1|NM|GLUC^Glucose^L^2345-7^Glucose^LN||101|mg/dL"]), ref)
    assert rows[0].loinc == "2345-7"


def test_comparator_values(ref):
    rows, _ = oru.map_oru(make(["OBX|1|NM|6598-7^TropT^LN||<6|ng/L",
                                "OBX|2|SN|4548-4^A1c^LN||>^14|%"]), ref)
    assert (rows[0].comparator, rows[0].value_numeric, rows[0].unit) == ("<", 0.006, "ng/mL")
    assert (rows[1].comparator, rows[1].value_numeric) == (">", 14.0)


def test_obx_level_rejects_do_not_block_panel(ref):
    msg = make(["OBX|1|NM|ZZZ^Unknown^L||1|mg/dL",
                "OBX|2|NM|2345-7^Glucose^LN||HEMOLYZED|mg/dL",
                "OBX|3|NM|2345-7^Glucose^LN||950|mg/L",
                "OBX|4|NM|2823-3^K^LN||4.1|mmol/L"])
    rows, rejects = oru.map_oru(msg, ref)
    assert [r.reason for r in rejects] == [oru.UNMAPPED_CODE, oru.NON_NUMERIC, oru.UNIT_NOT_CONVERTIBLE]
    assert [r.loinc for r in rows] == ["2823-3"]


def test_message_level_rejects(ref):
    assert oru.map_oru(make([], mtype="ADT^A08"), ref)[1][0].reason == oru.NOT_ORU
    no_mr = make(["OBX|1|NM|2345-7^G^LN||90|mg/dL"], pid="PID|1||555^^^PAYER^MB")
    assert oru.map_oru(no_mr, ref)[1][0].reason == oru.MISSING_MRN
    bad_ts = make(["OBX|1|NM|2345-7^G^LN||90|mg/dL"], msh7="yesterday")
    assert oru.map_oru(bad_ts, ref)[1][0].reason == oru.BAD_TIMESTAMP


def test_cancelled_result_needs_no_value(ref):
    rows, rejects = oru.map_oru(make(["OBX|1|NM|2951-2^Na^LN|||mmol/L|||||X"]), ref)
    assert not rejects and rows[0].result_status == "X" and rows[0].value_numeric is None


def test_text_result_unescaped(ref):
    rows, _ = oru.map_oru(make(["OBX|1|ST|5778-6^Color^LN||Yellow \\T\\ clear"]), ref)
    assert rows[0].value_text == "Yellow & clear"
