"""Generate synthetic Medicare Advantage-style members and claims for PY2026 RAF scoring.

Synthetic only -- no real people, no PHI. Deterministic (fixed seed).

Two populations:
  * Scenario members M9001-M9005 (+ unknown member M9999): hand-built edge
    cases with hand-calculated expected RAF values, used by the tests.
  * ~400 random members with realistic noise: denied claims, lab/radiology
    claims, voids and replacements, prior-year dates of service, SNF bills,
    dotted / lower-case / malformed ICD-10 codes, and an orphan dx line.

Usage:  python scripts/generate_data.py [--out data] [--members 400]
"""
from __future__ import annotations

import argparse
import csv
import random
from datetime import date, timedelta
from pathlib import Path

SEED = 20261110

# Diagnosis pool, weighted roughly like an aged MA population.
DX_POOL = [
    ("I10", 30), ("E78.5", 25), ("M54.5", 10), ("J06.9", 6), ("Z00.00", 8),
    ("E11.9", 14), ("E11.65", 6), ("E11.22", 5), ("E11.40", 4), ("E11.51", 2), ("E11.10", 1),
    ("I50.9", 5), ("I50.22", 3), ("I50.32", 3), ("I11.0", 3), ("I50.23", 1), ("I50.31", 1), ("I50.84", 1),
    ("J44.9", 8), ("J44.1", 2),
    ("N18.30", 4), ("N18.31", 3), ("N18.32", 2), ("N18.4", 2), ("N18.5", 1), ("N18.6", 1),
    ("F33.1", 4), ("F32.1", 2), ("E66.01", 4), ("Z68.41", 2), ("M06.9", 3),
    ("C61", 2), ("C50.911", 2), ("C79.51", 1), ("C78.7", 1),
]
PROF_VISIT_CPT = ["99213", "99214", "99215", "99204", "G0439", "99232", "99349"]

HEADER_COLS = ["claim_id", "claim_version", "frequency_code", "member_id", "claim_type", "bill_type",
               "cpt_code", "provider_specialty", "from_dos", "through_dos", "claim_status"]


class ClaimWriter:
    def __init__(self):
        self.headers: list[dict] = []
        self.dx: list[dict] = []
        self._n = 0

    def add(self, member_id, dx_codes, *, dos, claim_type="PROF", bill_type="", cpt="99214",
            specialty="INTERNAL_MEDICINE", status="PAID", los_days=0, claim_id=None,
            version=1, freq="1"):
        if claim_id is None:
            self._n += 1
            claim_id = f"CLM{self._n:07d}"
        self.headers.append(dict(
            claim_id=claim_id, claim_version=version, frequency_code=freq, member_id=member_id,
            claim_type=claim_type, bill_type=bill_type, cpt_code=cpt, provider_specialty=specialty,
            from_dos=dos.isoformat(), through_dos=(dos + timedelta(days=los_days)).isoformat(),
            claim_status=status,
        ))
        for seq, code in enumerate(dx_codes, start=1):
            self.dx.append(dict(claim_id=claim_id, claim_version=version, dx_seq=seq, icd10_raw=code))
        return claim_id


def scenario_members(cw: ClaimWriter) -> list[dict]:
    """Hand-built edge cases. Expected values are documented in tests/test_end_to_end.py."""
    members = [
        dict(member_id="M9001", sex="F", birth_date="1955-03-15"),  # age 70
        dict(member_id="M9002", sex="M", birth_date="1950-02-01"),  # turns 76 exactly on Feb 1
        dict(member_id="M9003", sex="F", birth_date="1961-06-30"),  # age 64
        dict(member_id="M9004", sex="M", birth_date="1940-12-31"),  # age 85
        dict(member_id="M9005", sex="F", birth_date="1958-02-02"),  # 67 -- birthday is one day after Feb 1
    ]
    d = date(2025, 4, 10)
    # M9001: diabetes 37 trumps 38; HF 224 trumps 226; DIABETES_HF interaction.
    cw.add("M9001", ["E11.22", "E11.9"], dos=d)
    cw.add("M9001", ["I50.23", "I50.9", "I10"], dos=d + timedelta(days=60), cpt="99215")

    # M9002: lab claim (ineligible), voided claim, prior-year DOS; only CKD 3a pays.
    cw.add("M9002", ["N18.4"], dos=d, cpt="80053", specialty="CLINICAL_LAB")
    cid = cw.add("M9002", ["J44.9"], dos=d)
    cw.add("M9002", [], dos=d, claim_id=cid, version=2, freq="8")
    cw.add("M9002", ["C50.911"], dos=date(2024, 12, 15))
    cw.add("M9002", ["N18.31"], dos=d + timedelta(days=30))

    # M9003: inpatient stay (bill 111) + hospital outpatient E/M (bill 131); 6 payment HCCs -> D6.
    cw.add("M9003", ["C78.7", "C79.51", "C50.911"], dos=date(2025, 7, 1), claim_type="INST",
           bill_type="111", cpt="", specialty="", los_days=5)
    cw.add("M9003", ["E66.01", "F33.1", "M06.9", "J44.1", "N18.5"], dos=date(2025, 9, 3),
           claim_type="INST", bill_type="131", cpt="99214", specialty="")
    # ...and a SNF bill (21x) that must not count.
    cw.add("M9003", ["E11.9"], dos=date(2025, 8, 1), claim_type="INST", bill_type="211",
           cpt="", specialty="", los_days=10)

    # M9004: original claim replaced (freq 7); denied claim; malformed code; messy-but-valid code.
    cid = cw.add("M9004", ["I50.9"], dos=d)
    cw.add("M9004", ["I50.84"], dos=d, claim_id=cid, version=2, freq="7")
    cw.add("M9004", ["E11.9"], dos=d + timedelta(days=10), status="DENIED")
    cw.add("M9004", ["11.9", " j44.9 "], dos=d + timedelta(days=20))

    # M9005: enrolled, no claims -> demographic score only.

    # Claim for a member who is not enrolled in the payment year.
    cw.add("M9999", ["E11.9"], dos=d)
    return members


def random_population(cw: ClaimWriter, rng: random.Random, n: int) -> list[dict]:
    codes, weights = zip(*DX_POOL)
    members = []
    for i in range(1, n + 1):
        mid = f"M{i:05d}"
        age = rng.choices([rng.randint(60, 64), rng.randint(65, 79), rng.randint(80, 97)], [1, 6, 3])[0]
        dob = date(2026 - age, 1, 1) + timedelta(days=rng.randint(0, 364))
        members.append(dict(member_id=mid, sex=rng.choice("FM"), birth_date=dob.isoformat()))

        burden = rng.choices([0, 1, 2, 4, 7], [12, 20, 30, 25, 13])[0]
        conditions = rng.choices(codes, weights, k=burden)
        for _ in range(rng.randint(0 if burden == 0 else 1, 6)):
            dos = date(2025, 1, 1) + timedelta(days=rng.randint(0, 364))
            if rng.random() < 0.06:                       # prior-year visit leaks into the extract
                dos = date(2024, rng.randint(10, 12), rng.randint(1, 28))
            dx = rng.sample(conditions, k=min(len(conditions), rng.randint(1, 4))) if conditions else ["Z00.00"]
            if rng.random() < 0.05:                       # sloppy upstream formatting
                dx = [c.lower().replace(".", "") for c in dx]
            if rng.random() < 0.02:
                dx.append(rng.choice(["1234", "E1#9", "XX", ""]))

            kind = rng.random()
            if kind < 0.70:
                cid = cw.add(mid, dx, dos=dos, cpt=rng.choice(PROF_VISIT_CPT),
                             status="DENIED" if rng.random() < 0.04 else "PAID")
            elif kind < 0.80:
                cid = cw.add(mid, dx, dos=dos, cpt=rng.choice(["80053", "36415", "85025"]), specialty="CLINICAL_LAB")
            elif kind < 0.85:
                cid = cw.add(mid, dx, dos=dos, cpt="71046", specialty="DIAGNOSTIC_RADIOLOGY")
            elif kind < 0.93:
                cid = cw.add(mid, dx, dos=dos, claim_type="INST", bill_type="111", cpt="", specialty="",
                             los_days=rng.randint(2, 7))
            elif kind < 0.97:
                cid = cw.add(mid, dx, dos=dos, claim_type="INST", bill_type="131",
                             cpt=rng.choice(["99214", "71046"]), specialty="")
            else:
                cid = cw.add(mid, dx, dos=dos, claim_type="INST", bill_type="211", cpt="", specialty="",
                             los_days=14)

            r = rng.random()
            if r < 0.03:                                  # void
                cw.add(mid, [], dos=dos, claim_id=cid, version=2, freq="8")
            elif r < 0.07:                                # replacement drops the last dx
                last = cw.headers[-1].copy()
                cw.add(mid, dx[:-1] or ["Z00.00"], dos=dos, claim_id=cid, version=2, freq="7",
                       claim_type=last["claim_type"], bill_type=last["bill_type"],
                       cpt=last["cpt_code"], specialty=last["provider_specialty"])
    return members


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[1] / "data"))
    ap.add_argument("--members", type=int, default=400)
    args = ap.parse_args()

    rng = random.Random(SEED)
    cw = ClaimWriter()
    members = scenario_members(cw) + random_population(cw, rng, args.members)
    # A diagnosis line whose header never arrived (feed timing issue).
    cw.dx.append(dict(claim_id="CLM_MISSING", claim_version=1, dx_seq=1, icd10_raw="I50.9"))

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, rows, cols in [
        ("members.csv", members, ["member_id", "sex", "birth_date"]),
        ("claim_headers.csv", cw.headers, HEADER_COLS),
        ("claim_diagnoses.csv", cw.dx, ["claim_id", "claim_version", "dx_seq", "icd10_raw"]),
    ]:
        with open(out / name, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(rows)
    print(f"members={len(members)} claim_versions={len(cw.headers)} dx_lines={len(cw.dx)} -> {out}")


if __name__ == "__main__":
    main()
