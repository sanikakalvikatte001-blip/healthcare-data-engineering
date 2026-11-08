"""End-to-end tests on a freshly generated synthetic extract."""
import dataclasses
import json

import polars as pl
import pytest

from safeharbor.cli import main
from safeharbor.pipeline import deidentify, read_inputs, write_outputs
from safeharbor.policy import PolicyError, Rule

from conftest import POLICY_PATH


@pytest.fixture(scope="module")
def result(policy, synthetic_dir):
    return deidentify(policy, read_inputs(policy, synthetic_dir), seed=7)


def test_gate_passes_on_synthetic_extract(result):
    assert result.passed
    fails = [c for c in result.checks if c.status == "fail"]
    assert fails == []


def test_released_columns_are_exactly_the_safe_ones(result):
    assert result.tables["patients"].columns == ["patient_key", "age_years", "birth_year", "sex", "state", "zip3"]
    assert result.tables["encounters"].columns == [
        "encounter_key", "patient_key", "admit_year", "discharge_year",
        "facility", "attending_npi", "primary_dx", "note_text"]


def test_row_counts_preserved_and_tables_still_join(result):
    p, e = result.tables["patients"], result.tables["encounters"]
    assert result.row_counts["patients"]["input_rows"] == p.height == 250
    assert result.row_counts["encounters"]["input_rows"] == e.height
    orphan = e.join(p, on="patient_key", how="anti")
    assert orphan.height == 0
    assert p["patient_key"].n_unique() == p.height


def test_notes_contain_no_patient_names(result, policy, synthetic_dir):
    src = read_inputs(policy, synthetic_dir)
    names = set(src["patients"]["last_name"].to_list())
    # Only provider names written as "Dr. X" may remain.
    notes = result.tables["encounters"]["note_text"].to_list()
    for note in notes:
        stripped = note.replace("Dr. Hughes", "")
        assert not any(f" {n} " in f" {stripped} " for n in names - {"Hughes"}), note


def test_redaction_counts_are_reported(result):
    red = result.redactions["encounters"]
    for tag in ("NAME", "PHONE", "DATE", "SSN", "EMAIL", "MRN", "URL", "ADDRESS"):
        assert red.get(tag, 0) > 0


def test_identifier_column_marked_keep_is_rejected(policy, synthetic_dir):
    """Someone marks SSN as 'keep': the policy lint refuses to run."""
    pt = policy.tables["patients"]
    bad = dataclasses.replace(policy, tables={**policy.tables, "patients": dataclasses.replace(
        pt, columns={**pt.columns, "ssn": Rule("keep")})})
    with pytest.raises(PolicyError, match="identifier-like columns marked keep.*ssn"):
        deidentify(bad, read_inputs(bad, synthetic_dir), seed=7)


def test_identifier_hidden_in_innocent_column_blocks_release(policy, synthetic_dir, tmp_path):
    """A 'source_record_ref' column that is really the MRN, and an unreviewed
    contact column, both reviewed as 'keep': the release gate catches the values
    and writes no data."""
    src = read_inputs(policy, synthetic_dir)
    src["encounters"] = src["encounters"].with_columns(pl.col("mrn").alias("source_record_ref"))
    src["patients"] = src["patients"].with_columns(pl.col("phone").alias("contact"))
    pt, et = policy.tables["patients"], policy.tables["encounters"]
    bad = dataclasses.replace(policy, tables={
        "patients": dataclasses.replace(pt, columns={**pt.columns, "contact": Rule("keep")}),
        "encounters": dataclasses.replace(et, columns={**et.columns, "source_record_ref": Rule("keep")}),
    })
    res = deidentify(bad, src, seed=7)
    assert not res.passed
    failed = {(c.table, c.name) for c in res.checks if c.status == "fail"}
    assert failed == {("encounters", "no_original_identifier_values"),
                      ("encounters", "residual_phi_patterns"),
                      ("patients", "no_original_identifier_values"),
                      ("patients", "residual_phi_patterns")}

    report = write_outputs(bad, res, tmp_path)
    assert report["released"] is False
    assert not (tmp_path / "release").exists()
    assert not (tmp_path / "restricted").exists()
    assert json.loads((tmp_path / "deid_report.json").read_text())["released"] is False


def test_new_source_column_stops_the_run(policy, synthetic_dir):
    src = read_inputs(policy, synthetic_dir)
    src["patients"] = src["patients"].with_columns(pl.lit("555-0100").alias("guarantor_phone"))
    with pytest.raises(PolicyError, match="guarantor_phone"):
        deidentify(policy, src, seed=7)


def test_cli_writes_release_and_restricted_crosswalk(synthetic_dir, tmp_path):
    rc = main(["--policy", str(POLICY_PATH), "--input", str(synthetic_dir),
               "--out", str(tmp_path), "--seed", "7"])
    assert rc == 0
    assert (tmp_path / "release" / "patients.csv").exists()
    cw = pl.read_csv(tmp_path / "restricted" / "crosswalk_patient.csv")
    rel = pl.read_csv(tmp_path / "release" / "patients.csv")
    assert set(cw["patient_key"]) == set(rel["patient_key"])
    assert "source_value" not in rel.columns


def test_cli_policy_error_exit_code(synthetic_dir, tmp_path):
    (tmp_path / "in").mkdir()
    df = pl.read_csv(synthetic_dir / "patients.csv", infer_schema=False).with_columns(pl.lit("x").alias("nickname"))
    df.write_csv(tmp_path / "in" / "patients.csv")
    (tmp_path / "in" / "encounters.csv").write_text((synthetic_dir / "encounters.csv").read_text())
    rc = main(["--policy", str(POLICY_PATH), "--input", str(tmp_path / "in"), "--out", str(tmp_path / "out")])
    assert rc == 2
