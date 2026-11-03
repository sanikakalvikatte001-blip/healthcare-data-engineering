"""Small hand-written exports that pin down one rule each."""
from conftest import collect_all, write_ndjson

LOINC = "http://loinc.org"


def patient(pid, version, updated, names=None, identifiers=None):
    return {
        "resourceType": "Patient", "id": pid,
        "meta": {"versionId": str(version), "lastUpdated": updated},
        "name": names or [{"use": "official", "family": "Doe", "given": ["Jan"]}],
        "identifier": identifiers or [],
        "gender": "unknown", "birthDate": "1980-01-01",
    }


def obs(oid, subject_ref, coding, **value):
    o = {"resourceType": "Observation", "id": oid, "meta": {"versionId": "1"},
         "status": "final", "code": {"coding": coding},
         "subject": {"reference": subject_ref}, "effectiveDateTime": "2026-10-01T08:00:00-05:00"}
    o.update(value)
    return o


def encounter(eid, subject_ref):
    return {"resourceType": "Encounter", "id": eid, "meta": {"versionId": "1"}, "status": "finished",
            "class": {"code": "AMB"}, "subject": {"reference": subject_ref},
            "period": {"start": "2026-10-01T08:00:00-05:00", "end": "2026-10-01T09:30:00-05:00"}}


def test_rules_on_tiny_export(spark, tmp_path):
    write_ndjson(tmp_path, "Patient.000.ndjson", [
        # version 2 in the first file, version 1 in the second
        patient("p1", 2, "2026-10-02T00:00:00Z",
                names=[{"use": "nickname", "given": ["JJ"]},
                       {"use": "official", "family": "Jones", "given": ["Jamie", "Lee", "Ann"]}],
                identifiers=[{"type": {"coding": [{"code": "MB"}]}, "value": "MBR-77"},
                             {"type": {"coding": [{"code": "MR"}]}, "value": "MRN-1"}]),
        "{not json at all",
    ])
    write_ndjson(tmp_path, "Patient.001.ndjson", [patient("p1", 1, "2026-10-01T00:00:00Z")])
    write_ndjson(tmp_path, "Encounter.000.ndjson", [encounter("e1", "Patient/p1")])
    write_ndjson(tmp_path, "Observation.000.ndjson", [
        obs("o1", "https://server/fhir/R4/Patient/p1",
            [{"system": "urn:local", "code": "GLU"}, {"system": LOINC, "code": "2345-7"}],
            valueQuantity={"value": 98, "code": "mg/dL"}),
        obs("o2", "Patient/nobody", [{"system": LOINC, "code": "2345-7"}],
            valueQuantity={"value": 101, "code": "mg/dL"}),
    ])

    out = collect_all(spark, tmp_path)

    # newest version, official name, MR identifier (not MB), middle names joined
    [p] = out["patient_flat"]
    assert (p["version_id"], p["family_name"], p["given_name"], p["middle_names"], p["mrn"]) == \
           (2, "Jones", "Jamie", "Lee Ann", "MRN-1")

    # offsets normalised to UTC; 1.5 hour visit
    [e] = out["encounter_flat"]
    assert e["length_of_stay_hours"] == 1.5 and e["period_start"].hour == 13

    # full URL reference resolves; LOINC picked from the second coding
    [o] = out["observation_flat"]
    assert (o["observation_id"], o["patient_id"], o["loinc_code"], o["value_numeric"]) == ("o1", "p1", "2345-7", 98.0)
    assert o["encounter_id"] is None   # no encounter reference on this observation

    reasons = sorted((q["resource_type"], q["reason"]) for q in out["quarantine"])
    assert reasons == [("Observation", "ORPHAN_PATIENT_REF"), ("Patient", "MALFORMED_JSON")]
    assert all(r["balanced"] for r in out["load_summary"])


def test_missing_resource_file_fails_fast(spark, tmp_path):
    import pytest
    from flatten_fhir import run_pipeline
    write_ndjson(tmp_path, "Patient.000.ndjson", [patient("p1", 1, "2026-10-01T00:00:00Z")])
    with pytest.raises(FileNotFoundError, match="Encounter"):
        run_pipeline(spark, tmp_path)
