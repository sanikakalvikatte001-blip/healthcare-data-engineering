"""End-to-end checks on the committed synthetic bulk export (data/export)."""


def by_id(rows, key):
    return {r[key]: r for r in rows}


def test_every_input_line_is_accounted_for(export_run):
    summary = by_id(export_run["load_summary"], "resource_type")
    assert set(summary) == {"Patient", "Encounter", "Observation"}
    assert all(r["balanced"] for r in summary.values())
    assert summary["Patient"]["input_lines"] == 46
    assert summary["Patient"]["superseded_lines"] == 6     # 5 older versions + 1 exact re-export
    assert summary["Observation"]["malformed_lines"] == 1


def test_one_row_per_patient_and_newest_version_wins(export_run, defects):
    patients = export_run["patient_flat"]
    assert len(patients) == len({p["patient_id"] for p in patients}) == 40
    pts = by_id(patients, "patient_id")
    for pid in defects["multi_version_patients"]:
        assert pts[pid]["version_id"] > 1
    # v3 lives in the FIRST file, v2 in the second: file order must not decide.
    assert pts[defects["patient_v3_out_of_order"][0]]["version_id"] == 3
    assert pts[defects["patient_v3_out_of_order"][0]]["source_file"] == "Patient.000.ndjson"


def test_official_name_and_mrn_picked_by_meaning_not_position(export_run, defects):
    p = by_id(export_run["patient_flat"], "patient_id")[defects["nickname_first_patient"][0]]
    assert p["family_name"] is not None            # nickname entry has no family name
    assert len(p["given_name"]) > 3                # not the 3-letter nickname
    assert all(r["mrn"].startswith("MRN") for r in export_run["patient_flat"])  # MR, not MB
    assert {r["birth_sex"] for r in export_run["patient_flat"]} <= {"F", "M"}


def test_orphans_go_to_quarantine(export_run, defects):
    q = {(r["resource_type"], r["resource_id"]): r["reason"] for r in export_run["quarantine"]}
    assert q[("Encounter", defects["orphan_encounter"][0])] == "ORPHAN_PATIENT_REF"
    assert q[("Observation", defects["orphan_obs"][0])] == "ORPHAN_PATIENT_REF"
    loaded_enc = {r["encounter_id"] for r in export_run["encounter_flat"]}
    assert defects["orphan_encounter"][0] not in loaded_enc


def test_observation_reject_reasons(export_run, defects):
    q = {r["resource_id"]: r["reason"] for r in export_run["quarantine"] if r["resource_type"] == "Observation"}
    for oid in defects["no_loinc_obs"]:
        assert q[oid] == "NO_LOINC_CODE"
    for oid in defects["entered_in_error_obs"]:
        assert q[oid] == "ENTERED_IN_ERROR"
    loaded = {r["observation_id"] for r in export_run["observation_flat"]}
    assert loaded.isdisjoint(q.keys())


def test_full_url_references_resolve(export_run, defects):
    obs = by_id(export_run["observation_flat"], "observation_id")
    for oid in defects["full_url_reference_obs"]:
        assert obs[oid]["patient_id"] is not None


def test_blood_pressure_panel_explodes_into_components(export_run):
    bp = [r for r in export_run["observation_flat"] if r["panel_loinc_code"] == "85354-9"]
    assert bp, "expected BP component rows"
    assert {r["loinc_code"] for r in bp} == {"8480-6", "8462-4"}
    per_obs = {}
    for r in bp:
        per_obs.setdefault(r["observation_id"], []).append(r["component_seq"])
    assert all(sorted(v) == [1, 2] for v in per_obs.values())
    assert all(r["value_unit_ucum"] == "mm[Hg]" for r in bp)


def test_value_choice_types(export_run, defects):
    obs = by_id([r for r in export_run["observation_flat"] if r["component_seq"] == 0], "observation_id")
    absent = obs[defects["data_absent_obs"][0]]
    assert absent["value_type"] == "absent" and absent["data_absent_reason"] == "not-performed"
    note = obs[defects["value_string_obs"][0]]
    assert note["value_type"] == "string" and note["value_text"].startswith("Patient reports")
    covid = [r for r in obs.values() if r["loinc_code"] == "94500-6"]
    assert covid and {r["value_display"] for r in covid} <= {"Positive", "Negative"}
    # LOINC chosen even though the local lab code is listed first
    assert any(r["loinc_code"] == "4548-4" for r in obs.values())


def test_in_progress_encounter_has_open_period(export_run, defects):
    enc = by_id(export_run["encounter_flat"], "encounter_id")[defects["in_progress_encounter"][0]]
    assert enc["status"] == "in-progress"
    assert enc["period_end"] is None and enc["length_of_stay_hours"] is None
    finished = [e for e in export_run["encounter_flat"] if e["status"] == "finished"]
    assert all(e["length_of_stay_hours"] > 0 for e in finished)


def test_latest_measures_mart(export_run):
    mart = export_run["patient_latest_measures"]
    assert len(mart) == len({r["patient_id"] for r in mart})
    assert all(r["systolic_bp"] is not None and r["systolic_bp"] > r["diastolic_bp"] for r in mart)
