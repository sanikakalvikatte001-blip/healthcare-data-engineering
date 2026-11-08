"""Free-text redaction for clinician notes.

Two passes, in this order:
  1. Pattern detectors (URL, e-mail, SSN, phone, dates, MRN, IP, street address).
     These catch identifiers of *anyone* written in a common format.
  2. Known values from the patient's own record (names, MRN, SSN, phone, ...).
     These catch identifiers with no fixed format, mainly names, which regexes
     can't find reliably. Patterns go first so an e-mail like
     "maria.alvarez@example.org" is redacted whole instead of becoming
     "[NAME].[NAME]@example.org".

Pattern detectors are also reused by verify.py to scan the *output* for residual PHI.
"""
from __future__ import annotations

import re
from collections import Counter
from typing import Iterable

_MONTH = (r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|"
          r"Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)")

# Ordered: earlier detectors win when matches overlap.
DETECTORS: dict[str, re.Pattern[str]] = {
    "URL": re.compile(r"\bhttps?://\S+|\bwww\.\S+", re.I),
    "EMAIL": re.compile(r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b"),
    "SSN": re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    "PHONE": re.compile(r"(?:\(\d{3}\)\s?|\b\d{3}[-.\s])\d{3}[-.\s]\d{4}\b"),
    "DATE": re.compile(
        r"\b\d{1,2}/\d{1,2}/\d{2,4}\b"                       # 03/14/2026
        r"|\b\d{4}-\d{2}-\d{2}\b"                            # 2026-03-14
        rf"|\b{_MONTH}\.?\s+\d{{1,2}}(?:st|nd|rd|th)?,?\s+\d{{4}}\b",  # March 14, 2026
        re.I,
    ),
    "MRN": re.compile(r"\bMRN\s*[:#]?\s*[A-Z0-9-]*\d[A-Z0-9-]*\b", re.I),
    "IP": re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    "ADDRESS": re.compile(
        r"\b\d{1,6}\s+(?:[A-Z][a-z]+\s+){1,3}"
        r"(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Lane|Ln|Drive|Dr|Ct|Court|Way)\b\.?"
    ),
}

# Tag used when a known value from a given source column is found.
KNOWN_VALUE_TAG = {
    "first_name": "NAME", "last_name": "NAME", "mrn": "MRN", "ssn": "SSN",
    "phone": "PHONE", "email": "EMAIL", "street": "ADDRESS", "city": "LOCATION",
}

_TOKEN = re.compile(r"\[[A-Z]+\]")


def scrub(text: str | None, known: dict[str, str | None] | None = None) -> tuple[str | None, Counter]:
    """Redact one note. Returns (scrubbed_text, Counter of redactions by tag)."""
    counts: Counter = Counter()
    if text is None or text == "":
        return text, counts

    for tag, pattern in DETECTORS.items():
        text, n = pattern.subn(f"[{tag}]", text)
        if n:
            counts[tag] += n

    if known:
        # Longest values first so "Mary Ann" wins over "Mary".
        items = sorted(
            ((v.strip(), col) for col, v in known.items() if v and len(v.strip()) >= 2),
            key=lambda kv: len(kv[0]), reverse=True,
        )
        for value, col in items:
            tag = KNOWN_VALUE_TAG.get(col, "REDACTED")
            # (?<!\w)/(?!\w) instead of \b so values starting with "(" still match.
            pat = re.compile(rf"(?<!\w){re.escape(value)}(?!\w)", re.I)
            text, n = pat.subn(f"[{tag}]", text)
            if n:
                counts[tag] += n
    return text, counts


def scrub_many(texts: Iterable[str | None], knowns: Iterable[dict[str, str | None]]):
    """Scrub a column of notes. Returns (list_of_texts, total Counter)."""
    out, total = [], Counter()
    for t, k in zip(texts, knowns):
        s, c = scrub(t, k)
        out.append(s)
        total.update(c)
    return out, total


def find_residual(text: str | None) -> list[str]:
    """Return the detector tags that still match in already-scrubbed text."""
    if not text:
        return []
    bare = _TOKEN.sub(" ", text)  # ignore our own [TAG] tokens
    return [tag for tag, p in DETECTORS.items() if p.search(bare)]


def contains_known(text: str | None, values: Iterable[str | None]) -> list[str]:
    """Return known values (len >= 2) that still appear as whole words in text."""
    if not text:
        return []
    hits = []
    for v in values:
        if v and len(v.strip()) >= 2 and re.search(rf"(?<!\w){re.escape(v.strip())}(?!\w)", text, re.I):
            hits.append(v)
    return hits
