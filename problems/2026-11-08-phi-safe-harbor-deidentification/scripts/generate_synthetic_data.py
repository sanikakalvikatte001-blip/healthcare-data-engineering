"""Generate a small, seeded, fully synthetic patient + encounter extract.

Nothing here is real PHI: names come from short generic lists, SSNs use the
never-issued 9xx area range, phone numbers use the 555-01xx fictional block,
and e-mails use the reserved example.org domain.

The extract is deliberately "dirty" in the ways real EHR extracts are:
  * a handful of patients are 90+ years old (Safe Harbor age rule)
  * some ZIP codes fall in sparsely populated 3-digit ZIP areas (<= 20,000 people)
  * clinician notes contain names, phone numbers, dates, MRNs, SSNs, e-mails,
    street addresses and URLs written inline

Usage:  python scripts/generate_synthetic_data.py --out data --seed 42
"""
from __future__ import annotations

import argparse
import csv
import random
from datetime import date, timedelta
from pathlib import Path

FIRST = ["Maria", "James", "Aisha", "Wei", "Carlos", "Priya", "John", "Fatima",
         "Liam", "Olivia", "Noah", "Emma", "Mateo", "Sofia", "Ethan", "Grace"]
LAST = ["Alvarez", "Brooks", "Chen", "Dawson", "Esposito", "Fischer", "Garcia",
        "Hughes", "Ibrahim", "Jensen", "Kowalski", "Lindqvist", "Moreau", "Nakamura"]
STREETS = ["Maple", "Oak", "Cedar", "Elm", "Lakeview", "Hillcrest", "Willow"]
SUFFIX = ["St", "Ave", "Rd", "Blvd", "Lane", "Drive"]
# (city, state, zip) — ordinary ZIPs plus several in restricted 3-digit ZIP areas
ZIPS = [("Columbus", "OH", "43215"), ("Austin", "TX", "78701"), ("Denver", "CO", "80202"),
        ("Raleigh", "NC", "27601"), ("Boston", "MA", "02108"), ("Tampa", "FL", "33602"),
        ("Seattle", "WA", "98101"), ("Madison", "WI", "53703")]
RESTRICTED_ZIPS = [("Newport", "VT", "05901"), ("Valentine", "NE", "69201"),
                   ("Ely", "NV", "89301"), ("Eagle Pass", "TX", "78852")]  # 059, 692, 893, 788(not restricted)
FACILITIES = ["NORTHWIND MED CTR", "CEDAR VALLEY HOSP", "LAKESIDE CLINIC"]
DX = ["E11.9", "I10", "J45.909", "N18.3", "I50.9", "F32.9", "M54.5", "Z00.00"]
NPIS = ["1245319599", "1679576722", "1003000126"]

NOTE_TEMPLATES = [
    "Pt {first} {last} seen for follow-up. Call back at {phone}.",
    "Mr./Ms. {last} reports improvement since visit on {date_us}. MRN {mrn}.",
    "Discussed plan with patient's daughter. Contact email {email}.",
    "Patient lives at {street}, {city}. Transport arranged for {date_iso}.",
    "Insurance verification: SSN {ssn} on file, member portal https://portal.example.org/u/{mrn}.",
    "{first} tolerating metformin well. Next labs {month_name} {day}, {year}.",
    "No acute distress. Vitals stable. Continue current regimen.",
    "Seen by Dr. Hughes. Pt {last}, {first} denies chest pain. Fax results to {phone}.",
]
MONTHS = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]


def fake_phone(rng: random.Random) -> str:
    return f"({rng.randint(200, 989)}) 555-01{rng.randint(0, 99):02d}"


def fake_ssn(rng: random.Random) -> str:
    return f"9{rng.randint(0, 99):02d}-{rng.randint(10, 99)}-{rng.randint(1000, 9999)}"


def build(seed: int, n_patients: int, as_of: date):
    rng = random.Random(seed)
    patients, encounters = [], []
    for i in range(n_patients):
        first, last = rng.choice(FIRST), rng.choice(LAST)
        # ~6% of patients are 90+ as of the reference date
        if rng.random() < 0.06:
            age = rng.randint(90, 101)
        else:
            age = rng.randint(1, 88)
        dob = as_of - timedelta(days=age * 365 + rng.randint(0, 364))
        city, state, zip5 = rng.choice(RESTRICTED_ZIPS) if rng.random() < 0.08 else rng.choice(ZIPS)
        mrn = f"MRN{100000 + i}"
        p = dict(
            mrn=mrn, first_name=first, last_name=last, dob=dob.isoformat(),
            sex=rng.choice(["F", "M"]), ssn=fake_ssn(rng), phone=fake_phone(rng),
            email=f"{first.lower()}.{last.lower()}{i}@example.org",
            street=f"{rng.randint(10, 9999)} {rng.choice(STREETS)} {rng.choice(SUFFIX)}",
            city=city, state=state, zip=zip5 + (f"-{rng.randint(1000, 9999)}" if rng.random() < 0.3 else ""),
            member_id=f"HP{rng.randint(10**8, 10**9 - 1)}",
        )
        patients.append(p)

        for _ in range(rng.randint(1, 5)):
            admit = as_of - timedelta(days=rng.randint(1, 900))
            discharge = admit + timedelta(days=rng.randint(0, 7))
            d = admit + timedelta(days=rng.randint(7, 60))
            note = rng.choice(NOTE_TEMPLATES).format(
                first=first, last=last, phone=fake_phone(rng), mrn=mrn, email=p["email"],
                street=p["street"], city=city, ssn=p["ssn"],
                date_us=admit.strftime("%m/%d/%Y"), date_iso=d.isoformat(),
                month_name=MONTHS[d.month - 1], day=d.day, year=d.year,
            )
            encounters.append(dict(
                encounter_id=f"ENC{len(encounters) + 1:06d}", mrn=mrn,
                admit_date=admit.isoformat(), discharge_date=discharge.isoformat(),
                facility=rng.choice(FACILITIES), attending_npi=rng.choice(NPIS),
                primary_dx=rng.choice(DX), note_text=note,
            ))
    return patients, encounters


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--patients", type=int, default=250)
    ap.add_argument("--as-of", default="2026-11-01")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    patients, encounters = build(args.seed, args.patients, date.fromisoformat(args.as_of))
    write_csv(out / "patients.csv", patients)
    write_csv(out / "encounters.csv", encounters)
    print(f"wrote {len(patients)} patients, {len(encounters)} encounters to {out}/")


if __name__ == "__main__":
    main()
