import csv
import json
import subprocess
import sys

from oru_feed.cli import main
from oru_feed.pipeline import process_feed, read_feed_dir

MSH = "MSH|^~\\&|LIS|NWLAB|HDE_INGEST|HDE|{ts}||ORU^R01|{ctl}|P|2.5.1"
PID = "PID|1||M1^^^NWHS^MR"
OBR = "OBR|1||ACC1|BMP^BMP^L|||202610290800-0400"


def msg(ctl, ts, value, status):
    return "\r".join([MSH.format(ts=ts, ctl=ctl), PID, OBR,
                      f"OBX|1|NM|2823-3^Potassium^LN||{value}|mmol/L|||||{status}"])


def test_latest_version_wins_and_cancel_removes(ref):
    texts = [msg("A", "202610290900-0400", 6.1, "P"),
             msg("C", "202610291100-0400", 5.2, "C"),   # arrives out of order
             msg("B", "202610291000-0400", 5.4, "F")]
    res = process_feed(texts, ref)
    assert len(res.current) == 1
    assert (res.current[0].value_numeric, res.current[0].result_status) == (5.2, "C")
    assert res.superseded == 2

    res = process_feed(texts + [msg("D", "202610291200-0400", "", "X")], ref)
    assert res.current == [] and res.cancelled == 1


def test_duplicate_control_id_is_acked_not_loaded(ref):
    m = msg("A", "202610290900-0400", 4.0, "F")
    res = process_feed([m, m], ref)
    assert res.duplicate_messages == 1
    assert res.observations_parsed == 1
    assert all("MSA|AA|A|" in a for a in res.acks)


def test_ack_codes(ref):
    good = msg("G", "202610290900-0400", 4.0, "F")
    partial = good.replace("|G|", "|P1|") + "\rOBX|2|NM|ZZZ^x^L||1|mg/dL"
    res = process_feed([good, partial, "garbage"], ref)
    codes = [a.split("MSA|")[1][:2] for a in res.acks]
    assert codes == ["AA", "AE", "AR"]


def test_end_to_end_on_synthetic_feed(tmp_path, root, ref):
    data = tmp_path / "data"
    subprocess.run([sys.executable, str(root / "tools" / "make_feed.py"), "--out", str(data)], check=True)
    out = tmp_path / "out"
    rc = main(["--input", str(data), "--config", str(root / "config"), "--out", str(out)])
    assert rc == 0

    s = json.loads((out / "run_summary.json").read_text())
    assert s["messages_read"] == 56
    assert s["duplicate_messages_skipped"] == 1
    assert s["observations_current"] == (s["observations_parsed"] - s["observations_superseded"]
                                         - s["observations_cancelled"])
    assert s["rejects_by_reason"] == {"BAD_TIMESTAMP": 1, "MISSING_MRN": 1, "NON_NUMERIC_VALUE": 1,
                                      "NOT_ORU_R01": 1, "UNIT_NOT_CONVERTIBLE": 1, "UNMAPPED_CODE": 2}
    assert sum(s["acks_by_code"].values()) == s["messages_read"]

    rows = list(csv.DictReader(open(out / "observations.csv")))
    # Every loaded numeric result is in its canonical unit
    canon = {"2345-7": "mg/dL", "2160-0": "mg/dL", "4548-4": "%", "2823-3": "mmol/L", "2951-2": "mmol/L"}
    for r in rows:
        if r["loinc"] in canon:
            assert r["unit"] == canon[r["loinc"]], r
    # Grain is unique: one current row per (facility, accession, LOINC)
    keys = [(r["sending_facility"], r["accession_number"], r["loinc"]) for r in rows]
    assert len(keys) == len(set(keys))
    # No cancelled results survive
    assert not any(r["result_status"] in ("X", "D") for r in rows)


def test_reject_rate_gate(tmp_path, root):
    data = tmp_path / "data"
    subprocess.run([sys.executable, str(root / "tools" / "make_feed.py"), "--out", str(data)], check=True)
    args = ["--input", str(data), "--config", str(root / "config"), "--out", str(tmp_path / "o")]
    assert main(args + ["--fail-on-reject-rate", "0.5"]) == 0
    assert main(args + ["--fail-on-reject-rate", "0.01"]) == 2
