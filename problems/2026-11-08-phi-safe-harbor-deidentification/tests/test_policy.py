import pytest

from safeharbor.policy import PolicyError, Rule, check_coverage, load_policy


def test_rule_parsing():
    assert Rule.parse("surrogate:patient") == Rule("surrogate", "patient")
    assert Rule.parse(" keep ") == Rule("keep")
    with pytest.raises(PolicyError):
        Rule.parse("mask")
    with pytest.raises(PolicyError):
        Rule.parse("surrogate:bad-domain")


def test_shipped_policy_loads(policy):
    assert set(policy.tables) == {"patients", "encounters"}
    assert len(policy.restricted_zip3) == 17
    assert policy.tables["encounters"].scrub.link_table == "patients"


def test_unknown_column_fails_closed(policy):
    cols = list(policy.tables["patients"].columns) + ["emergency_contact_phone"]
    with pytest.raises(PolicyError, match="no de-identification rule.*emergency_contact_phone"):
        check_coverage(policy.tables["patients"], cols)


def test_missing_column_is_reported(policy):
    cols = [c for c in policy.tables["patients"].columns if c != "zip"]
    with pytest.raises(PolicyError, match="not found in input.*zip"):
        check_coverage(policy.tables["patients"], cols)


def test_scrub_link_must_reference_policy_columns(tmp_path):
    p = tmp_path / "p.toml"
    p.write_text("""
[run]
as_of_date = "2026-11-01"
[tables.a]
file = "a.csv"
[tables.a.columns]
id = "keep"
[tables.b]
file = "b.csv"
[tables.b.columns]
note = "scrub_text"
[tables.b.scrub]
column = "note"
link_table = "a"
link_key = "id"
known_values = ["first_name"]
""")
    with pytest.raises(PolicyError, match="link columns not in a"):
        load_policy(p)


def test_identifier_name_hint_matches_whole_tokens():
    from safeharbor.policy import IDENTIFIER_NAME_HINT as H
    for name in ["ssn", "patient_ssn", "home_phone", "vehicle_vin", "mrn", "subscriber_id"]:
        assert H.search(name), name
    for name in ["province", "sex", "primary_dx", "facility", "attending_npi", "state"]:
        assert not H.search(name), name
