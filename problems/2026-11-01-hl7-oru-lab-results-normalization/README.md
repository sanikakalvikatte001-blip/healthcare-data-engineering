# HL7 v2 ORU^R01 lab results → LOINC-coded, unit-normalized observations

A small, **standard-library-only** Python CLI that ingests HL7 v2 lab result feeds from two labs, normalizes every result to LOINC and a canonical unit, applies corrections and cancellations, and sends an ACK back for every message.

## Problem

Lab results reach a clinical data warehouse as HL7 v2 `ORU^R01` messages. Each lab sends them in its own way:

- **Different codes:** one lab sends LOINC in OBX-3. Another sends local codes (`GLU`, `CREAT`). A third puts LOINC only in the *alternate* coding triplet.
- **Different units:** US labs report glucose in mg/dL and HbA1c in %. Labs that use SI units send mmol/L, µmol/L and IFCC mmol/mol.
- **Results change after they are sent:** a preliminary (`P`) result becomes final (`F`), then gets corrected (`C`) or cancelled (`X`). The corrected report re-sends the whole panel, not just the changed line.
- **Messy transport:** messages come MLLP-framed or as batch files, with CR or LF line endings, and with non-default delimiters declared in MSH-2. Interface-engine retries resend the same MSH-10. Free text carries HL7 escape sequences (`\T\`, `\S\`, `\F\`).
- **Bad data:** missing MRNs, `"<6"` or `"HEMOLYZED"` sent as numeric (`NM`), units nobody configured, unreadable timestamps, and ADT messages mixed into the lab channel.

## Why it matters

- **HEDIS and quality measures:** HbA1c control (GSD/CDC), kidney health (KED) and similar measures look up results by LOINC and compare them to thresholds. A result in mmol/mol compared to `< 8.0 %` is silently wrong.
- **Clinical safety:** a corrected potassium result that doesn't replace the original leaves the wrong value in front of care managers.
- **Interface operations:** labs need an `AE`/`AR` ACK to know a result was not accepted. Without a reject queue with reason codes, analysts end up grepping raw files.

## Approach

```
data/*.hl7 ──► split_stream ──► parse_message ──► dedupe MSH-10 ──► map_oru (per OBX) ──► resolve_current_state
                (MLLP/batch)    (MSH-2 delims,    (retries ACK'd    LOINC + unit + value    (P→F→C, X/D removes)
                                 escapes)          but not loaded)   or Reject(reason)
                                                                          │
                                                       output/observations.csv · rejects.csv · acks.hl7 · run_summary.json
```

| Module | Responsibility |
|---|---|
| `src/oru_feed/hl7.py` | HL7 v2 reader: reads delimiters from MSH-1/MSH-2, handles repetitions, components and sub-components, escape sequences, MLLP framing and FHS/BHS batch envelopes. HL7 positions are 1-based (`seg.get(3, 5, rep=2)`). |
| `src/oru_feed/reference.py` | Loads the config CSVs: lab registry and time zones, local-code → LOINC crosswalk, unit conversions per LOINC (`canonical = value × factor + offset`). |
| `src/oru_feed/oru.py` | Maps one ORU^R01 to `Observation` rows. Picks the `MR` identifier from repeating PID-3. Handles NM, SN, CWE and ST values. Uses OBX-14 for the result time and falls back to OBR-7. Turns timestamps without an offset into UTC using the lab's IANA time zone, which keeps DST correct. |
| `src/oru_feed/pipeline.py` | Feed-level steps: skips duplicate MSH-10s, reduces result versions to the latest per `(facility, accession, LOINC)`, builds `AA`/`AE`/`AR` ACKs, writes the outputs. |
| `src/oru_feed/cli.py` | `python -m oru_feed`. `--fail-on-reject-rate` gives a non-zero exit code so a scheduler can alert on it. |

Key decisions:

- **Rejects are per OBX, not per message.** One unmapped Vitamin D code doesn't drop the hemoglobin in the same message. That message gets an `AE` ACK instead of `AR`.
- **Onboarding a lab is a config change.** Mapping a new local code or accepting a new unit means adding a CSV row in `config/`, with no code change.
- **Values are traceable.** Each row keeps `source_value`, `source_unit` and `source_code` next to the normalized values, so you can audit any conversion.
- **Versions are ordered by MSH-7, not by arrival.** A late `F` can't overwrite an earlier-arriving `C`.

## How to run

Requires Python 3.10+. The solution uses only the standard library. pytest is needed for the tests.

```bash
cd problems/2026-11-01-hl7-oru-lab-results-normalization
pip install -r requirements.txt

python tools/make_feed.py --out data                  # synthetic feed (seeded, no PHI)
PYTHONPATH=src python -m oru_feed --input data --config config --out output
python -m pytest -q
```

## Results

Synthetic feed: 56 messages from 2 labs. NWLAB sends 33 messages, MLLP-framed and LOINC-coded. CEDAR sends 23 messages with local codes, SI units, `#` as the component delimiter and LF line endings.

| Metric | Value |
|---|---:|
| Messages read | 56 |
| Duplicate MSH-10 resends skipped | 1 |
| OBX results parsed | 140 |
| Superseded by a later version | 6 |
| Cancelled (`X`) and removed | 1 |
| **Current observations loaded** | **133** |
| Patients with results | 27 |
| ACKs | 50 `AA` · 2 `AE` · 4 `AR` |

The 6 superseded results break down as:

- 4 from one corrected glucose report. The lab re-sent the full BMP, so all 4 lines were replaced, and only glucose has status `C` (70 → 112 mg/dL).
- 1 preliminary potassium replaced by its final result (6.1 → 5.4 mmol/L).
- 1 sodium result that was later cancelled.

Rejects (`output/rejects.csv`):

| Reason | Count | Example |
|---|---:|---|
| `UNMAPPED_CODE` | 2 | CEDAR `VITD25`, `FERR` not in crosswalk yet (same message's HGB still loaded) |
| `NON_NUMERIC_VALUE` | 1 | `NM` value `HEMOLYZED` |
| `UNIT_NOT_CONVERTIBLE` | 1 | glucose in `mg/L` (not an accepted unit) |
| `BAD_TIMESTAMP` | 1 | MSH-7 `2026-10-29 08:15` |
| `MISSING_MRN` | 1 | PID-3 has only a payer member id |
| `NOT_ORU_R01` | 1 | `ADT^A08` on the lab channel |

Sample conversions from the output:

- CEDAR glucose 12.6 mmol/L → 227.0 mg/dL.
- Creatinine 121 µmol/L → 1.37 mg/dL.
- HbA1c 74 mmol/mol → 8.92 %.
- HbA1c sent as SN `>130` mmol/mol → comparator `>` and 14.04 %.
- Troponin `<6` ng/L sent as NM → comparator `<` and 0.006 ng/mL.
- Text result `Yellow \T\ clear` → `Yellow & clear`.

Tests: **20 passed**. They cover the parser, mapping and conversion, version resolution, ACK codes, an end-to-end run and the reject-rate gate.
