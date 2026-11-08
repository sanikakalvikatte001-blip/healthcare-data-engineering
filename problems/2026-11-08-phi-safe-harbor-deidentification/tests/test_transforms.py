from datetime import date

import polars as pl

from safeharbor.transforms import SurrogateRegistry, dob_to_age, to_year, to_zip3

RESTRICTED = frozenset({"059", "692", "893"})


def test_zip3_rules():
    df = pl.DataFrame({"zip": ["43215", "43215-1234", "05901", "69201-0001", "893", "ABCDE", " 02108", None]})
    out = df.select(to_zip3("zip", RESTRICTED))["zip3"].to_list()
    # ordinary, ZIP+4, restricted x3, malformed, leading space kept leading zero, null
    assert out == ["432", "432", "000", "000", "000", "000", "021", "000"]


def test_to_year_drops_month_and_day():
    df = pl.DataFrame({"admit_date": ["2025-02-28", "2024-12-31", "not a date"]})
    out = df.select(to_year("admit_date"))
    assert out.columns == ["admit_year"]
    assert out["admit_year"].to_list() == [2025, 2024, None]


def test_dob_to_age_birthday_boundaries_and_top_code():
    as_of = date(2026, 11, 1)
    df = pl.DataFrame({"dob": [
        "1990-11-01",  # birthday today -> 36
        "1990-11-02",  # birthday tomorrow -> 35
        "1937-11-01",  # turns 89 today... 89
        "1936-11-02",  # 89 (90th birthday is tomorrow)
        "1936-11-01",  # 90 today -> top-coded, birth year removed
        "1921-05-05",  # 105 -> 90, birth year removed
        "2026-02-10",  # infant -> 0
    ]})
    out = df.select(dob_to_age("dob", as_of))
    assert out["age_years"].to_list() == [36, 35, 89, 89, 90, 90, 0]
    assert out["birth_year"].to_list() == [1990, 1990, 1937, 1936, None, None, 2026]


def test_surrogates_consistent_across_tables_and_random():
    reg = SurrogateRegistry(seed=1)
    reg.register("patient", ["MRN1", "MRN2", None])
    reg.register("patient", ["MRN2", "MRN3"])            # second table, overlapping keys
    m = reg.maps["patient"]
    assert set(m) == {"MRN1", "MRN2", "MRN3"}
    assert len(set(m.values())) == 3
    assert all(t.startswith("PAT-") and "MRN" not in t for t in m.values())

    df = pl.DataFrame({"mrn": ["MRN2", "MRN1", "MRN2"]})
    keys = df.select(reg.expr("mrn", "patient"))["patient_key"].to_list()
    assert keys[0] == keys[2] == m["MRN2"]

    # Not derived from the value: a different seed gives different tokens.
    other = SurrogateRegistry(seed=2)
    other.register("patient", ["MRN1", "MRN2", "MRN3"])
    assert other.maps["patient"] != m

    cw = reg.crosswalk("patient")
    assert cw.columns == ["source_value", "patient_key"] and cw.height == 3


def test_unseeded_registry_uses_system_rng():
    a, b = SurrogateRegistry(), SurrogateRegistry()
    a.register("patient", ["MRN1"])
    b.register("patient", ["MRN1"])
    assert a.maps["patient"]["MRN1"] != b.maps["patient"]["MRN1"]
