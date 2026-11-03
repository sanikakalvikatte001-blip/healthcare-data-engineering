"""
Generate a small, synthetic FHIR R4 Bulk Data ($export) drop as NDJSON.

Helper only: the solution itself is the Spark SQL in ../sql. Everything here is
fake (random names, MRNs, phone numbers) - no real PHI.

Output (data/export/):
    Patient.000.ndjson, Patient.001.ndjson   - two export files, versions spread across both
    Encounter.000.ndjson
    Observation.000.ndjson
    planted_defects.json                     - ids of the edge cases, used by the tests

Edge cases planted on purpose (all common in real bulk exports):
    * the same Patient exported more than once with different meta.versionId,
      and the newest version is NOT in the last file
    * an exact duplicate line (same id + same version) re-exported
    * a patient whose first name[] entry is a nickname, not the official name
    * references written as full URLs instead of "Patient/<id>"
    * Encounter / Observation pointing at a Patient that is not in the export
    * Observations whose code has only a local lab code (no LOINC)
    * Observations with status entered-in-error
    * an Observation with dataAbsentReason instead of a value
    * a truncated (malformed) JSON line
"""
from __future__ import annotations

import json
import random
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

SEED = 20261103
N_PATIENTS = 40
BASE_URL = "https://fhir.example-health.org/R4"
LOINC = "http://loinc.org"
SNOMED = "http://snomed.info/sct"
UCUM = "http://unitsofmeasure.org"
LOCAL_LAB = "urn:oid:2.16.840.1.113883.3.9999.5.1"   # fake local lab code system
MRN_SYSTEM = "urn:oid:2.16.840.1.113883.3.9999.1"     # fake hospital MRN system
V2_0203 = "http://terminology.hl7.org/CodeSystem/v2-0203"

FAMILY = ["Rivera", "Nguyen", "Patel", "Okafor", "Schmidt", "Kowalski", "Haddad",
          "Tanaka", "Moreau", "Silva", "Johansson", "Brennan", "Mensah", "Ivanova"]
GIVEN_F = ["Ava", "Maya", "Leila", "Grace", "Nora", "Priya", "Hana", "Chloe"]
GIVEN_M = ["Liam", "Omar", "Mateo", "Ethan", "Kenji", "Lucas", "Arjun", "Noah"]

rng = random.Random(SEED)


def new_id() -> str:
    """Deterministic UUID (FHIR ids from most EHR exports look like this)."""
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def iso(ts: datetime) -> str:
    return ts.isoformat(timespec="seconds").replace("+00:00", "Z")


def make_patient(pid: str, mrn: str, version: int, updated: datetime,
                 nickname_first: bool = False) -> dict:
    sex = rng.choice(["female", "male"])
    given = rng.choice(GIVEN_F if sex == "female" else GIVEN_M)
    family = rng.choice(FAMILY)
    birth = date(1940, 1, 1) + timedelta(days=rng.randint(0, 365 * 65))
    names = [{"use": "official", "family": family, "given": [given, rng.choice("ABCDEJKLMR") + "."]}]
    if nickname_first:
        names.insert(0, {"use": "nickname", "given": [given[:3]]})
    return {
        "resourceType": "Patient",
        "id": pid,
        "meta": {"versionId": str(version), "lastUpdated": iso(updated)},
        "extension": [{
            "url": "http://hl7.org/fhir/us/core/StructureDefinition/us-core-birthsex",
            "valueCode": "F" if sex == "female" else "M",
        }],
        "identifier": [
            {"type": {"coding": [{"system": V2_0203, "code": "MB"}]},
             "system": "urn:oid:2.16.840.1.113883.3.9999.2", "value": f"MBR{rng.randint(10**8, 10**9 - 1)}"},
            {"type": {"coding": [{"system": V2_0203, "code": "MR"}]},
             "system": MRN_SYSTEM, "value": mrn},
        ],
        "name": names,
        "gender": sex,
        "birthDate": birth.isoformat(),
        "telecom": [
            {"system": "email", "value": f"{given.lower()}.{family.lower()}@example.com"},
            {"system": "phone", "value": f"555-{rng.randint(100, 999)}-{rng.randint(1000, 9999)}", "use": "home"},
        ],
        "address": [{"use": "home", "state": rng.choice(["NJ", "NY", "PA", "CT"]),
                     "postalCode": f"0{rng.randint(7000, 8999)}"}],
        "deceasedBoolean": False,
    }


def ref(resource_type: str, rid: str, full_url: bool = False) -> dict:
    return {"reference": f"{BASE_URL}/{resource_type}/{rid}" if full_url else f"{resource_type}/{rid}"}


def quantity(value: float, unit: str) -> dict:
    return {"value": value, "unit": unit, "system": UCUM, "code": unit}


def codeable(*codings: tuple[str, str, str]) -> dict:
    return {"coding": [{"system": s, "code": c, "display": d} for s, c, d in codings]}


def observation(oid, pid, eid, when, category, code, status="final", full_url=False, **value) -> dict:
    obs = {
        "resourceType": "Observation",
        "id": oid,
        "meta": {"versionId": "1", "lastUpdated": iso(when + timedelta(hours=2))},
        "status": status,
        "category": [codeable(("http://terminology.hl7.org/CodeSystem/observation-category", category, category))],
        "code": code,
        "subject": ref("Patient", pid, full_url),
        "encounter": ref("Encounter", eid),
        "effectiveDateTime": iso(when),
    }
    obs.update(value)
    return obs


def main() -> None:
    out = Path(__file__).resolve().parents[1] / "data" / "export"
    out.mkdir(parents=True, exist_ok=True)
    defects: dict[str, list[str]] = {}
    t0 = datetime(2026, 9, 1, tzinfo=timezone.utc)

    # ---------------- Patients ----------------
    patients = [(new_id(), f"MRN{100000 + i}") for i in range(N_PATIENTS)]
    file0, file1 = [], []
    for i, (pid, mrn) in enumerate(patients):
        file0.append(make_patient(pid, mrn, 1, t0, nickname_first=(i == 5)))
    defects["nickname_first_patient"] = [patients[5][0]]

    # Patients 0-2 get a version 2 in file 001 (address/phone change).
    for pid, mrn in patients[0:3]:
        file1.append(make_patient(pid, mrn, 2, t0 + timedelta(days=20)))
    # Patient 3: version 3 sits in file 000, older version 2 sits in file 001,
    # so "last file wins" would load the wrong row.
    pid3, mrn3 = patients[3]
    file0.append(make_patient(pid3, mrn3, 3, t0 + timedelta(days=30)))
    file1.append(make_patient(pid3, mrn3, 2, t0 + timedelta(days=10)))
    # Patient 4: identical line re-exported (same id + same version).
    file1.append(file0[4])
    defects["multi_version_patients"] = [p for p, _ in patients[0:4]]
    defects["patient_v3_out_of_order"] = [pid3]
    defects["exact_duplicate_patient"] = [patients[4][0]]

    # ---------------- Encounters & Observations ----------------
    encounters, observations = [], []
    lab_patients = set(p for p, _ in patients[::3])  # every 3rd patient gets labs
    for pid, _ in patients:
        for _ in range(rng.randint(1, 3)):
            eid = new_id()
            start = t0 + timedelta(days=rng.randint(0, 55), hours=rng.randint(7, 17))
            cls = rng.choices(["AMB", "EMER", "IMP"], weights=[7, 2, 1])[0]
            hours = {"AMB": 1, "EMER": rng.randint(3, 9), "IMP": rng.randint(30, 120)}[cls]
            encounters.append({
                "resourceType": "Encounter", "id": eid,
                "meta": {"versionId": "1", "lastUpdated": iso(start + timedelta(hours=hours))},
                "status": "finished",
                "class": {"system": "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code": cls},
                "type": [codeable((SNOMED, {"AMB": "185349003", "EMER": "50849002", "IMP": "32485007"}[cls],
                                   {"AMB": "Encounter for check up", "EMER": "Emergency room admission",
                                    "IMP": "Hospital admission"}[cls]))],
                "subject": ref("Patient", pid),
                "period": {"start": iso(start), "end": iso(start + timedelta(hours=hours))},
            })
            # Vitals for every encounter: BP panel (2 components), heart rate, weight.
            observations.append(observation(
                new_id(), pid, eid, start, "vital-signs",
                codeable((LOINC, "85354-9", "Blood pressure panel")),
                component=[
                    {"code": codeable((LOINC, "8480-6", "Systolic blood pressure")),
                     "valueQuantity": quantity(rng.randint(104, 168), "mm[Hg]")},
                    {"code": codeable((LOINC, "8462-4", "Diastolic blood pressure")),
                     "valueQuantity": quantity(rng.randint(62, 102), "mm[Hg]")},
                ]))
            observations.append(observation(
                new_id(), pid, eid, start, "vital-signs",
                codeable((LOINC, "8867-4", "Heart rate")),
                valueQuantity=quantity(rng.randint(55, 110), "/min")))
            observations.append(observation(
                new_id(), pid, eid, start, "vital-signs",
                codeable((LOINC, "29463-7", "Body weight")),
                valueQuantity=quantity(round(rng.uniform(48, 125), 1), "kg")))
            if pid in lab_patients:
                # Lab results: local code listed FIRST, LOINC second (typical of lab interfaces).
                observations.append(observation(
                    new_id(), pid, eid, start + timedelta(hours=1), "laboratory",
                    codeable((LOCAL_LAB, "HGBA1C", "HbA1c"), (LOINC, "4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood")),
                    valueQuantity=quantity(round(rng.uniform(5.0, 10.5), 1), "%")))
                observations.append(observation(
                    new_id(), pid, eid, start + timedelta(hours=1), "laboratory",
                    codeable((LOCAL_LAB, "SARSCOV2PCR", "COVID PCR"),
                             (LOINC, "94500-6", "SARS-CoV-2 RNA [Presence] in Respiratory system specimen by NAA with probe detection")),
                    valueCodeableConcept=codeable(rng.choice([(SNOMED, "260385009", "Negative"),
                                                              (SNOMED, "10828004", "Positive")]))))

    # -- Planted encounter defects --
    ghost_patient = new_id()
    orphan_enc = encounters[0].copy()
    orphan_enc.update(id=new_id(), subject=ref("Patient", ghost_patient))
    encounters.append(orphan_enc)
    defects["orphan_encounter"] = [orphan_enc["id"]]

    encounters[7]["status"] = "in-progress"
    del encounters[7]["period"]["end"]
    defects["in_progress_encounter"] = [encounters[7]["id"]]

    # -- Planted observation defects (picked from the generated list) --
    hr_obs = [o for o in observations if o["code"]["coding"][0]["code"] == "8867-4"]
    lab_obs = [o for o in observations if o["category"][0]["coding"][0]["code"] == "laboratory"]

    # Full-URL subject references (valid, must still resolve).
    for o in hr_obs[0:2]:
        o["subject"]["reference"] = f"{BASE_URL}/{o['subject']['reference']}"
    defects["full_url_reference_obs"] = [o["id"] for o in hr_obs[0:2]]

    # Local code only -> no LOINC.
    for o in lab_obs[0:2]:
        o["code"]["coding"] = o["code"]["coding"][:1]
    defects["no_loinc_obs"] = [o["id"] for o in lab_obs[0:2]]

    # Entered in error.
    for o in hr_obs[2:4]:
        o["status"] = "entered-in-error"
    defects["entered_in_error_obs"] = [o["id"] for o in hr_obs[2:4]]

    # Value missing with a reason (valid FHIR, must be kept).
    dar = hr_obs[4]
    del dar["valueQuantity"]
    dar["dataAbsentReason"] = codeable(("http://terminology.hl7.org/CodeSystem/data-absent-reason",
                                        "not-performed", "Not Performed"))
    defects["data_absent_obs"] = [dar["id"]]

    # Free-text note observation (valueString).
    note = observation(new_id(), patients[1][0], encounters[1]["id"], t0, "exam",
                       codeable((LOINC, "48767-8", "Annotation comment")),
                       valueString="Patient reports improved sleep after medication change.")
    observations.append(note)
    defects["value_string_obs"] = [note["id"]]

    # Orphan subject.
    orphan_obs = observation(new_id(), ghost_patient, orphan_enc["id"], t0, "vital-signs",
                             codeable((LOINC, "8867-4", "Heart rate")),
                             valueQuantity=quantity(77, "/min"))
    observations.append(orphan_obs)
    defects["orphan_obs"] = [orphan_obs["id"]]

    # ---------------- Write NDJSON ----------------
    def write(name: str, rows: list[dict], extra_lines: list[str] = ()) -> None:
        with open(out / name, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, separators=(",", ":")) + "\n")
            for line in extra_lines:
                fh.write(line + "\n")

    write("Patient.000.ndjson", file0)
    write("Patient.001.ndjson", file1)
    write("Encounter.000.ndjson", encounters)
    # A line cut off mid-write (e.g. export job killed) - must be quarantined, not crash the load.
    broken = json.dumps(observations[10], separators=(",", ":"))[:120]
    write("Observation.000.ndjson", observations, [broken])

    (out.parent / "planted_defects.json").write_text(json.dumps(defects, indent=2) + "\n")
    print(f"patients={N_PATIENTS} patient_lines={len(file0) + len(file1)} "
          f"encounters={len(encounters)} observations={len(observations)} (+1 malformed line)")


if __name__ == "__main__":
    main()
