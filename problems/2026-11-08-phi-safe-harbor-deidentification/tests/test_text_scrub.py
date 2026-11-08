import pytest

from safeharbor.text_scrub import contains_known, find_residual, scrub


@pytest.mark.parametrize("text, tag", [
    ("SSN 912-34-5678 on file", "SSN"),
    ("call (614) 555-0123", "PHONE"),
    ("call 614-555-0123", "PHONE"),
    ("call 614.555.0123", "PHONE"),
    ("seen 03/14/2026", "DATE"),
    ("seen 2026-03-14", "DATE"),
    ("next labs March 14, 2026", "DATE"),
    ("next labs Sept 3rd 2026", "DATE"),
    ("mail jo.doe+1@example.org", "EMAIL"),
    ("see https://portal.example.org/u/123", "URL"),
    ("MRN: A12345 noted", "MRN"),
    ("from 10.1.22.130", "IP"),
    ("lives at 42 Maple Ave", "ADDRESS"),
])
def test_each_detector_redacts(text, tag):
    out, counts = scrub(text)
    assert f"[{tag}]" in out
    assert counts[tag] == 1
    assert find_residual(out) == []


def test_clinical_codes_are_not_redacted():
    # ICD-10, NPI (10 digits, no separators), vitals and doses must survive.
    text = "Dx E11.9 and I10. NPI 1245319599. BP 128/82. Metformin 500 mg BID."
    out, counts = scrub(text)
    assert out == text
    assert sum(counts.values()) == 0


def test_known_names_are_redacted_case_insensitive_whole_words():
    out, counts = scrub("Pt CHEN, wei seen. Weiss family visited.",
                        {"first_name": "Wei", "last_name": "Chen"})
    assert out == "Pt [NAME], [NAME] seen. Weiss family visited."
    assert counts["NAME"] == 2


def test_patterns_run_before_names_so_email_is_redacted_whole():
    out, _ = scrub("email maria.alvarez3@example.org",
                   {"first_name": "Maria", "last_name": "Alvarez"})
    assert out == "email [EMAIL]"


def test_known_value_starting_with_parenthesis():
    # Phone in an odd format the pattern can't see, but it's on the patient record.
    out, counts = scrub("reach at (614)5550123 ext 2", {"phone": "(614)5550123"})
    assert out == "reach at [PHONE] ext 2"
    assert counts["PHONE"] == 1


def test_longest_known_value_wins():
    out, _ = scrub("Mary Ann came in", {"first_name": "Mary Ann", "last_name": "Mary"})
    assert out == "[NAME] came in"


def test_empty_and_none_text():
    assert scrub(None)[0] is None
    assert scrub("")[0] == ""


def test_residual_scan_ignores_redaction_tokens():
    assert find_residual("Pt [NAME] called [PHONE] on [DATE]") == []
    assert find_residual("Pt called 614-555-0123") == ["PHONE"]


def test_contains_known():
    assert contains_known("Pt Chen seen", ["Chen", None, "x"]) == ["Chen"]
    assert contains_known("Pt Cheng seen", ["Chen"]) == []
