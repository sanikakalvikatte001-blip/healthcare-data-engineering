# Master Patient Index: probabilistic patient matching across EHR, lab and payer feeds

**Tech:** PostgreSQL 16 · PL/pgSQL (procedure + `MERGE`) · `fuzzystrmatch` · `pg_trgm` · pgTAP

## Problem

One patient shows up in many systems under many identifiers: an MRN in the EHR, an accession-linked ID in the lab system, a member ID at the payer. The demographics never line up exactly:

- **Formats differ.** `1984-07-09` vs `07/09/1984` vs `19840709`; `F` vs `Female` vs `2`; `(212) 555-0143` vs `12125550143`.
- **People are recorded differently.** "Bob" vs "Robert", a typo in the surname, day and month swapped, a new surname after marriage, a new address after a move.
- **Values are fake.** Registration clerks enter `999-99-9999` or `123-45-6789` when the patient has no SSN at hand.
- **Lookalikes are not the same person.** Twins share surname, DOB, address and phone. A father and son ("Jr.") share name, address and phone.
- **Charts get duplicated.** Registrars miss an existing MRN and create a second chart in the same EHR.

A Master Patient Index (MPI) has to assign one **enterprise patient ID** per real person across all of this, every day, as new registrations arrive.

## Why it matters

- **Overlays** (two people on one ID) are a patient-safety event: one person's allergies, labs or meds show up in another person's chart. They are also a HIPAA disclosure risk.
- **Duplicates** (one person on two IDs) split the clinical history. They cause repeat tests, wrong HEDIS/quality denominators (gaps in care that were really closed), and broken readmission and attribution logic.
- Duplicate rates of roughly 8–12% are commonly cited for hospital MPIs, and duplicate cleanup is expensive manual HIM work.

So the matcher must **never overlay**, should link as much as it safely can, and should send the uncertain cases to a person.

## Approach

```
stg.patient_registration ──► reject unusable rows ──► MERGE into mpi.source_patient (normalized, latest message wins)
                                                            │
                                         blocking keys ◄────┘
                                               │
                               score candidate pairs (Fellegi-Sunter weights from a config table)
                                               │
              AUTO_LINK ≥ 12 ─────► link / create / merge enterprise IDs (procedural, record by record)
              REVIEW 7–12   ─────► mpi.review_queue (data steward)
              NON_MATCH < 7
```

| Step | Where | Design choice |
|---|---|---|
| Normalize | `V003__normalization_functions.sql` | One function per field. Placeholder SSNs, all-zero phones, impossible / future DOBs become `NULL`, so they carry no false evidence. Nicknames are resolved through a lookup table. |
| Upsert | `mpi.process_batch` step 2 | `MERGE` with `DISTINCT ON` keeps the latest message per source record. A `record_hash` means unchanged resends do nothing. |
| Block | `mpi.block_keys()` | Five overlapping keys (DOB + surname soundex, DOB + first-name metaphone, SSN, phone, names + ZIP). Only records that share a key are compared, so there is no O(n²) cross join, and a single bad field cannot hide a match. |
| Score | `mpi.score_pair()` + `mpi.match_weight` | Each field returns AGREE / PARTIAL / DISAGREE / MISSING. The weights are rows in a table, so stewards can tune them without a code change. Every scored pair is stored with its per-field outcomes, so any link can be explained. |
| Link | `mpi.process_batch` step 5 | A `FOR` loop, on purpose. Each decision depends on links made just before it in the same batch. If a new record auto-links to two existing IDs, they are **merged** (the oldest ID survives, the retired ID points to it, and an audit row is written). |
| Guard rails | step 5 / 6 | Two MRNs from the **same source** are never auto-linked or auto-merged. They go to review as `SAME_SOURCE_DUPLICATE` / `MERGE_BLOCKED_SAME_SOURCE`, because collapsing a duplicate chart is an HIM decision. Identity is **sticky**: a demographic update does not move a record to another enterprise ID. |

Weights that matter for the hard cases:

- **First name disagreement is −4.** Twins agree on everything except first name and SSN. When the SSN is missing, they drop into review instead of auto-linking.
- **SSN one digit apart is 0, not partial credit.** Twins often get consecutive SSNs. A pgTAP test caught that awarding partial credit pushed twins over the auto-link threshold.
- **Surname disagreement is only −2.** People change surnames, so a mismatch alone should not block a link.

## How to run

Needs PostgreSQL 15+ (for `MERGE`) with the contrib extensions, plus pgTAP / `pg_prove` for tests. The `Dockerfile` gives you both.

```bash
export PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres   # PGDATABASE defaults to mpi_demo
make run      # migrations -> synthetic feed -> CALL mpi.process_batch() for both batches
make report   # volumes, decisions, review queue, precision / recall
make test     # rebuilds, then runs the pgTAP suite with pg_prove
```

```
db/migrations/V001..V006   schemas, config, normalization, scoring, procedure, evaluation views
db/seed/                   synthetic registration feed (SQL, seeded random - no real PHI)
reports/match_quality.sql  run report
tests/                     pgTAP: 01 normalization, 02 scoring, 03 end-to-end pipeline
```

**Synthetic data.** There are 385 made-up people. That includes 15 sets of twins and 10 father/son "Jr." pairs. They produce 820 registration messages in two batches:

- **B20261101** (385 messages) — EHR initial load. It includes 12 duplicate charts and 3 unusable rows.
- **B20261102** (435 messages) — lab and payer feeds, plus 20 EHR resends that arrive twice. In the lab and payer records, people were given nicknames, typos, swapped DOBs, missing or placeholder SSNs, surname changes, moves and walk-in records with almost no demographics. 15 people appear for the first time in this batch.

SSNs use the never-issued 9xx area and phones use the fictional 555-01xx range. `stg.synthetic_truth` holds the true person behind each record. Only the report and tests read it; the matcher never does.

## Results

From `make run && make report` (PostgreSQL 16.15):

| Metric | Value |
|---|---|
| Source records loaded / rejected | 777 / 3 (1 missing name, 2 invalid DOB) |
| True people | 385 |
| Active enterprise IDs | 400 |
| Batch 1 → new IDs | 382 |
| Batch 2 → links / new IDs | 377 / 18 |
| Scored pairs (auto-link / review / non-match) | 487 / 49 / 355 — out of ~300k possible pairs, thanks to blocking |
| **Pairwise precision (no overlays)** | **1.0000** (0 false links) |
| Pairwise recall (automatic only) | 0.9431 (464 of 492 true pairs) |
| Twin / Jr-Sr pairs on one ID | **0** |

Review queue: 73 items.

| Reason | Items | Truly same person |
|---|---|---|
| `SAME_SOURCE_DUPLICATE` | 12 | 12 |
| `MERGE_BLOCKED_SAME_SOURCE` | 12 | 12 |
| `SCORE_IN_REVIEW_BAND` | 49 | 4 |

The review band behaves as intended. Of its 49 pairs, 45 are the twins, Jr/Sr pairs and other lookalikes that a person should look at, and only 4 are true matches. Every split person (the 15 extra IDs) has a review item that joins their two IDs. The pipeline test checks this, so no duplicate is silent.

Recall by data-quality issue (non-EHR record linked to the person's EHR chart):

| Issue | Records | Recall |
|---|---|---|
| clean | 141 | 1.000 |
| no SSN | 173 | 0.988 |
| nickname | 25 | 1.000 |
| surname typo | 25 | 0.920 |
| minimal demographics (no phone/address) | 26 | 0.923 |
| moved | 17 | 1.000 |
| surname change | 13 | 1.000 |
| placeholder SSN | 7 | 1.000 |
| DOB day/month swap | 4 | 1.000 |

The only automatic misses are 2 lab records that combine a surname typo with no SSN, phone or address. They sit in review.

Tests: `pg_prove` runs **56 assertions in 3 files — all pass**. They cover normalization edge cases, the scoring of twins, Jr/Sr pairs, nicknames and surname changes, integrity (no merge chains, everything on an active ID), latest-resend-wins, sticky identity, idempotent re-runs, and a bridging record that merges two enterprise IDs.
