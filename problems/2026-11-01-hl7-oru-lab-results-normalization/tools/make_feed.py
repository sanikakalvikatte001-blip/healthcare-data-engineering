"""Generate a small, fully synthetic two-lab ORU^R01 feed (no real PHI).

* NWLAB  - LOINC-coded, conventional US units, MLLP-framed capture, CR segment
           terminators, timestamps carry a UTC offset.
* CEDAR  - local codes, SI units, non-default component delimiter '#',
           LF line endings, timestamps in local time (America/Chicago).

A fixed set of real-world defects is injected on top so the pipeline's
handling can be verified: resends, corrections, a cancellation, unmapped
codes, a missing MRN, non-numeric NM, an unconvertible unit, a bad
timestamp, a non-ORU message, and HL7 escape sequences.

    python tools/make_feed.py --out data
"""
from __future__ import annotations

import argparse
import random
from datetime import datetime, timedelta
from pathlib import Path

SEED = 20261101

# (code, text, system, unit, low, high, decimals) per lab
NW_TESTS = {
    "BMP": [("2345-7", "Glucose", "LN", "mg/dL", 70, 240, 0),
            ("2160-0", "Creatinine", "LN", "mg/dL", 0.6, 2.4, 2),
            ("2823-3", "Potassium", "LN", "mmol/L", 3.3, 5.6, 1),
            ("2951-2", "Sodium", "LN", "mmol/L", 132, 147, 0)],
    "A1C": [("4548-4", "Hemoglobin A1c", "LN", "%", 5.0, 10.5, 1)],
}
CEDAR_TESTS = {
    "BMP": [("GLU", "Glucose", "L", "mmol/L", 3.9, 13.3, 1),
            ("CREAT", "Creatinine", "L", "umol/L", 53, 210, 0),
            ("K", "Potassium", "L", "mmol/L", 3.3, 5.6, 1),
            ("NA", "Sodium", "L", "mmol/L", 132, 147, 0)],
    "A1C": [("A1C", "HbA1c IFCC", "L", "mmol/mol", 31, 91, 0)],
}


def ts(dt: datetime, offset: str | None) -> str:
    return dt.strftime("%Y%m%d%H%M") + (offset or "")


def ny_offset(dt: datetime) -> str:
    # DST in 2026 ends Nov 1 at 02:00 local; all synthetic dates are before that.
    return "-0400"


def nw_message(i, mrn, panel, obx_rows, when, status="F", ctl=None):
    ctl = ctl or f"NW{i:05d}"
    off = ny_offset(when)
    segs = [
        f"MSH|^~\\&|NWLIS|NWLAB|HDE_INGEST|HDE|{ts(when + timedelta(hours=3), off)}||ORU^R01^ORU_R01|{ctl}|P|2.5.1",
        f"PID|1||{mrn}^^^NWHS^MR~900{i:06d}^^^SYNTHPAYER^MB||Synthetic^Patient{i}||19700101|U",
        f"OBR|1|PL{i:05d}|NWACC{i:05d}|{panel}^{panel} panel^L|||{ts(when, off)}||||||||||||||||{status}",
    ]
    for n, (code, text, system, vtype, value, unit, rng, flag, st) in enumerate(obx_rows, 1):
        segs.append(f"OBX|{n}|{vtype}|{code}^{text}^{system}||{value}|{unit}|{rng}|{flag}|||{st}|||{ts(when, off)}")
    return "\r".join(segs)


def cedar_message(i, mrn, panel, obx_rows, when, ctl=None, msh7=None):
    ctl = ctl or f"CED{i:05d}"
    msh7 = msh7 or ts(when + timedelta(hours=2), None)
    segs = [
        f"MSH|#~\\&|CEDARLIS|CEDAR|HDE_INGEST|HDE|{msh7}||ORU#R01#ORU_R01|{ctl}|P|2.5.1",
        f"PID|1||C{mrn}###CEDAR#MR||Synthetic#Patient{i}||19650505|U",
        f"OBR|1||CEDACC{i:05d}|{panel}#{panel}#L|||{ts(when, None)}||||||||||||||||F",
    ]
    for n, (code, text, system, vtype, value, unit, rng, flag, st) in enumerate(obx_rows, 1):
        segs.append(f"OBX|{n}|{vtype}|{code}#{text}#{system}||{value}|{unit}|{rng}|{flag}|||{st}|||{ts(when, None)}")
    return "\n".join(segs)


def random_rows(rnd, tests, panel):
    rows = []
    for code, text, system, unit, lo, hi, dec in tests[panel]:
        v = round(rnd.uniform(lo, hi), dec)
        v = int(v) if dec == 0 else v
        rows.append([code, text, system, "NM", v, unit, f"{lo}-{hi}", "", "F"])
    return rows


def build(out_dir: Path) -> None:
    rnd = random.Random(SEED)
    base = datetime(2026, 10, 20, 7, 0)
    nw, cedar = [], []

    # ---- clean baseline traffic -------------------------------------------
    for i in range(1, 25):
        panel = "BMP" if i % 3 else "A1C"
        when = base + timedelta(hours=7 * i)
        nw.append(nw_message(i, f"NW{1000 + i % 15}", panel, random_rows(rnd, NW_TESTS, panel), when))
    for i in range(1, 19):
        panel = "BMP" if i % 3 else "A1C"
        when = base + timedelta(hours=9 * i)
        cedar.append(cedar_message(i, 2000 + i % 12, panel, random_rows(rnd, CEDAR_TESTS, panel), when))

    # ---- injected defects / edge cases ----------------------------------------
    when = base + timedelta(days=9)
    # 1) interface-engine resend of NW00003 (identical MSH-10)
    nw.append(nw[2])
    # 2) correction: NW00005 glucose re-issued with status C and a new value
    orig = nw[4]
    corrected = orig.replace("|ORU^R01^ORU_R01|NW00005|", "|ORU^R01^ORU_R01|NW00005C|")
    corrected = corrected.replace(ts(base + timedelta(hours=38), "-0400"),
                                  ts(base + timedelta(hours=60), "-0400"), 1)  # later MSH-7
    lines = corrected.split("\r")
    for k, ln in enumerate(lines):
        if ln.startswith("OBX|1|"):
            parts = ln.split("|")
            parts[5], parts[11] = "112", "C"
            lines[k] = "|".join(parts)
    nw.append("\r".join(lines))
    # 3) preliminary then final troponin-like: P potassium followed by F
    p_rows = [["2823-3", "Potassium", "LN", "NM", 6.1, "mmol/L", "3.5-5.1", "H", "P"]]
    nw.append(nw_message(101, "NW1001", "BMP", p_rows, when))
    f_rows = [["2823-3", "Potassium", "LN", "NM", 5.4, "mmol/L", "3.5-5.1", "H", "F"]]
    nw.append(nw_message(101, "NW1001", "BMP", f_rows, when + timedelta(minutes=50), ctl="NW00101F"))
    # 4) cancelled result: sodium sent F, then X (specimen hemolyzed)
    nw.append(nw_message(102, "NW1002", "BMP",
                         [["2951-2", "Sodium", "LN", "NM", 139, "mmol/L", "135-145", "", "F"]], when))
    nw.append(nw_message(102, "NW1002", "BMP",
                         [["2951-2", "Sodium", "LN", "NM", "", "mmol/L", "135-145", "", "X"]],
                         when + timedelta(hours=1), ctl="NW00102X"))
    # 5) LOINC only in the alternate triplet + escape sequences in a text result
    alt = [["GLUC", "Glucose", "L^2345-7^Glucose^LN", "NM", 101, "mg/dL", "70-99", "H", "F"],
           ["5778-6", "Color of Urine", "LN", "ST", "Yellow \\T\\ clear", "", "", "", "F"]]
    nw.append(nw_message(103, "NW1003", "BMP", alt, when))
    # 6) missing MRN (only a payer id in PID-3)
    nw.append(nw_message(104, "NW1004", "A1C",
                         [["4548-4", "Hemoglobin A1c", "LN", "NM", 6.8, "%", "4.0-5.6", "H", "F"]], when)
              .replace("NW1004^^^NWHS^MR~", ""))
    # 7) non-ORU message sharing the interface
    nw.append(f"MSH|^~\\&|NWADT|NWLAB|HDE_INGEST|HDE|{ts(when, '-0400')}||ADT^A08|NW00105|P|2.5.1\r"
              "PID|1||NW1005^^^NWHS^MR||Synthetic^Patient105")

    # Cedar defects
    # 8) unmapped local codes (Vitamin D, Ferritin not in crosswalk yet)
    cedar.append(cedar_message(201, 2001, "MISC",
                               [["VITD25", "Vitamin D 25-OH", "L", "NM", 62, "nmol/L", "75-250", "L", "F"],
                                ["FERR", "Ferritin", "L", "NM", 40, "ug/L", "15-150", "", "F"],
                                ["HGB", "Hemoglobin", "L", "NM", 128, "g/L", "120-160", "", "F"]], when))
    # 9) NM with comparator, CWE culture, and a non-numeric NM
    cedar.append(cedar_message(202, 2002, "MISC",
                               [["TROP", "Troponin T hs", "L", "NM", "<6", "ng/L", "0-14", "", "F"],
                                ["UCULT", "Urine culture", "L", "CWE", "264395009#Escherichia coli#SCT",
                                 "", "", "A", "F"],
                                ["GLU", "Glucose", "L", "NM", "HEMOLYZED", "mmol/L", "3.9-5.5", "", "F"]], when))
    # 10) unit that cannot be converted for glucose
    cedar.append(cedar_message(203, 2003, "BMP",
                               [["GLU", "Glucose", "L", "NM", 950, "mg/L", "3.9-5.5", "", "F"]], when))
    # 11) structurally bad MSH-7 timestamp
    cedar.append(cedar_message(204, 2004, "BMP",
                               [["K", "Potassium", "L", "NM", 4.2, "mmol/L", "3.5-5.1", "", "F"]],
                               when, msh7="2026-10-29 08:15"))
    # 12) SN structured numeric + NTE with escaped delimiter
    sn = cedar_message(205, 2005, "A1C",
                       [["A1C", "HbA1c IFCC", "L", "SN", ">#130", "mmol/mol", "20-42", "HH", "F"]], when)
    cedar.append(sn + "\nNTE|1|L|Result verified by repeat analysis \\S\\ dilution 1\\F\\2")

    out_dir.mkdir(parents=True, exist_ok=True)
    framed = "".join(f"\x0b{m}\r\x1c\r" for m in nw)
    (out_dir / "nwlab_20261029.hl7").write_text(framed, encoding="utf-8", newline="")
    (out_dir / "cedar_20261029.hl7").write_text("\n".join(cedar) + "\n", encoding="utf-8")
    print(f"wrote {len(nw)} NWLAB and {len(cedar)} CEDAR messages to {out_dir}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data")
    build(Path(ap.parse_args().out))
