# C-CDA document ingestion: dedup by file hash + canonical XML hash, versioning (RPLC) and entry-level dedup

**Tech:** C# (.NET 8), LINQ to XML, SHA-256, class library + console worker, xUnit-style tests · DuckDB SQL for the warehouse-side reconciliation

## Problem

An HIE or partner EHR sends a daily drop of C-CDA documents (CCDs, encounter summaries) over SFTP. In practice the drop is messy:

| What arrives | Why it happens | What a naive loader does |
|---|---|---|
| The same file twice | SFTP/MLLP retries, gateway resends | Loads every problem, med and lab twice |
| The same document, different bytes | A gateway re-serializes it (tabs, CRLF, BOM, attribute order, added comments or stylesheet PI) | A plain file hash misses it, so it loads twice |
| Version 2 of a document (`setId` + `versionNumber`, `relatedDocument typeCode="RPLC"`) | The clinician corrected the chart | Keeps both versions, so a resolved asthma problem stays "active" |
| Version 1 arriving *after* version 2 | An interface engine replays its queue | Rolls the chart back to stale data |
| A reused document id with different content | An upstream id-generation bug | Overwrites a good document |
| Truncated XML, or no patient identifier | The transfer was cut off, or the export was bad | Crashes the job, or loads data you can't attach to a patient |
| Different documents that overlap | Every CCD is a full snapshot, so diabetes and metformin appear in every one | The same fact shows up N times in the warehouse |

## Why it matters

- **Quality measures and care gaps.** Duplicated or stale problems and labs distort HEDIS/MIPS numerators and denominators. A superseded "active" asthma can keep a patient in a measure they no longer qualify for.
- **Clinical safety.** Allergy and medication lists have to reflect the latest version of the chart, never an older replay.
- **Audit.** Every file that arrives needs a recorded decision and reason (loaded, duplicate, superseded, stale, rejected), so interface teams can trace issues back to the sender.
- **Reruns.** Daily jobs get re-run. Loading the same batch again must not change anything.

## Approach

```
inbox/batchN/*.xml
   │  1. SHA-256 of raw bytes ───────────── seen? → DuplicateFile
   │  2. XXE-safe parse + header validation ─ bad? → RejectedInvalid   (reason recorded)
   │  3. SHA-256 of canonical XML ────────── seen? → DuplicateContent
   │  4. document id already used ────────────────→ RejectedIdConflict
   │  5. setId held at version ≥ this one ─────────→ StaleVersion
   │  6. setId held at a lower version ────────────→ Loaded, old version → Superseded
   ▼  7. otherwise ────────────────────────────────→ Loaded
state/ (ledger, persisted between runs)        curated/ (rebuilt every run)
  document_manifest.csv  one row per file        curated_patients / problems / medications /
  document_entries.csv   raw entries per doc     allergies / results.csv  - one row per clinical fact
  document_patients.csv, entry_exceptions.csv
```

Key decisions:

- **Two fingerprints.** The raw-bytes hash is cheap and catches exact resends before any parsing. The **canonical hash** (`Hashing/DocumentFingerprint.cs`) catches re-serialized resends. It is a practical subset of W3C C14N: comments and PIs dropped, whitespace collapsed, attributes sorted, names resolved to namespace URIs (prefix-independent).
- **Rule order is deliberate.** A byte-identical retry of a *rejected* file is still just a duplicate. Rejected and stale files never claim a canonical hash or document id, so a later good file is never blocked. The id-conflict check runs before the versioning check, so a reused id can never overwrite a set.
- **Versioning by `setId` + `versionNumber`.** Only one version per set is active. A late v1 after v2 is recorded as `StaleVersion` and ignored.
- **Sections found by LOINC section code** (11450-4 problems, 10160-0 meds, 48765-2 allergies, 30954-2 results), not by templateId, because templateId extensions vary by vendor and C-CDA release.
- **Entry-level dedup with natural keys** (`Curation/ClinicalCurator.cs`):
  - problem and allergy: patient + code
  - medication: patient + RxNorm + start date (a restart counts as a new order)
  - result: patient + LOINC + date

  Attributes come from the most recent active document, and the source document count plus first and last seen document are kept for lineage.
- **Curated layer = pure function of the ledger.** It is rebuilt from `Loaded` documents on every run, so when an RPLC drops a fact, that fact disappears without any delete logic.
- **Entry exceptions instead of silent drops.** An entry with `nullFlavor="UNK"` goes to `entry_exceptions.csv`.
- **Idempotent, all-or-nothing batches.** State is loaded once and saved once per batch, and a replayed batch produces only `DuplicateFile` rows.
- **Independent SQL check** (`sql/load_and_reconcile.sql`). This loads the outputs into DuckDB tables with primary keys, recomputes the dedup set-based with `row_number()`, and reconciles row-by-row against the C# output with `EXCEPT`. It also checks that every inbox file has one manifest row and that each set has at most one active version.

```
src/CcdaIngest/
  Hashing/DocumentFingerprint.cs   file + canonical SHA-256
  Parsing/CcdaParser.cs            header, patient, 4 sections, HL7 TS parsing, XXE-safe load
  Ingestion/DocumentRegistry.cs    document-level rules (the decision table above)
  Ingestion/IngestionPipeline.cs   batch orchestration against an IStateStore
  Curation/ClinicalCurator.cs      entry-level dedup → curated tables
  Storage/                         CSV ledger (CsvStateStore) and InMemoryStateStore for tests
  Synthetic/                       C-CDA R2.1-shaped document builder + the two-day synthetic feed
  Program.cs                       CLI: generate | ingest
tests/CcdaIngest.Tests/            41 test cases ([Fact] / [Theory] + [InlineData])
sql/                               DuckDB load + reconciliation (helper)
```

## How to run

You need the .NET 8 SDK (`apt-get install -y dotnet-sdk-8.0`) and, for the SQL reconciliation, `pip install -r sql/requirements.txt`.

```bash
./run.sh          # build → generate → ingest batch1 → ingest batch2 → DuckDB reconciliation → tests

# or step by step
dotnet build CcdaIngest.sln
dotnet run --project src/CcdaIngest -- generate --inbox data/inbox
dotnet run --project src/CcdaIngest -- ingest --inbox data/inbox/batch1 --batch-id batch1 --out output
dotnet run --project src/CcdaIngest -- ingest --inbox data/inbox/batch2 --batch-id batch2 --out output
python3 sql/run_sql_checks.py
dotnet run --project tests/CcdaIngest.Tests
```

> **Note on tests:** the build sandbox had no NuGet access (api.nuget.org was blocked), so the solution uses only the base class library. The test project includes `XunitLite.cs`, a ~110-line runner that supports the same `[Fact]`, `[Theory]`/`[InlineData]` and `Assert.*` API. Switching to real xUnit only means adding the package references and deleting that one file.

The data is all synthetic: invented names and MRNs, with OIDs under the HL7 example root `2.16.840.1.113883.19`. Codes are public SNOMED CT, RxNorm and LOINC concepts.

## Results

There were 13 files over two daily drops (`output/run_summary_batch1.txt`, `output/run_summary_batch2.txt`):

```
=== C-CDA ingestion: batch2 ===
file                           status              reason
01_ccd_100001_gateway.xml      DuplicateContent    Same canonical XML as an earlier file (re-serialized resend)
02_ccd_100002_resend.xml       DuplicateFile       Byte-identical to a file already received
03_ccd_100002_v2.xml           Loaded              Replaces version 1 of setId
04_ccd_100003_v1_late.xml      StaleVersion        Version 1 arrived after version 2 of the same setId
05_enc_100001.xml              Loaded              New document
06_ccd_100004_reissued.xml     RejectedIdConflict  Document id already used by 05_ccd_100004.xml with different content
07_ccd_no_patient_id.xml       RejectedInvalid     Missing patient identifier (patientRole/id with root and extension)

Manifest (all batches) by status:
  Loaded                5
  Superseded            1
  DuplicateFile         2
  DuplicateContent      1
  StaleVersion          1
  RejectedIdConflict    1
  RejectedInvalid       2

Active documents: 5; raw entries in active documents: 33; curated entries: 27 (6 cross-document duplicates collapsed)
Curated patients: 4
  Problem      8
  Medication   7
  Allergy      4
  Result       8
Entry exceptions (all batches): 1
```

What the numbers show:

- **Only 5 of 13 files feed the warehouse.** A file-hash-only loader would have caught just the 2 exact resends. It would have loaded the re-serialized resend (different bytes, BOM and CRLF, but the same canonical hash), the late stale v1 and the id-conflict reissue, and it would have kept the superseded v1 active.
- **6 cross-document duplicates collapsed** for Ava (MRN 100001), whose CCD and encounter summary overlap: diabetes, hypertension, metformin, lisinopril, penicillin allergy, and the 2026-10-28 HbA1c. Lisinopril takes its status from the newer document (`completed`, ended 2026-11-11) and keeps `source_document_count = 2` for lineage.
- **The RPLC replacement wins.** Marcus (100002) shows asthma `completed` (ended 2026-11-08) and albuterol stopped. His v1's unmapped `nullFlavor` problem is logged in `entry_exceptions.csv` and does not appear in the curated data.
- **The late v1 for Priya (100003) changed nothing.** Her CKD stage 3 from v2 is still there.
- **The reissued Gerald (100004) document was quarantined.** His glucose stays at 104 mg/dL, not the conflicting 99.

DuckDB reconciliation (`output/sql_reconciliation.txt`):

```
  PASS  every inbox file has exactly one manifest row                          expected=13   actual=13
  PASS  at most one Loaded document per set_id                                 expected=0    actual=0
  PASS  every DuplicateFile hash belongs to an earlier accepted-or-logged file expected=0    actual=0
  PASS  no raw entries from rejected / stale / duplicate documents             expected=0    actual=0
  PASS  curated row count = SQL re-derivation                                  expected=27   actual=27
  PASS  curated rows differing from SQL re-derivation                          expected=0    actual=0
  PASS  curated rows sourced only from active (Loaded) documents               expected=0    actual=0
7/7 SQL reconciliation checks passed
```

Tests: **41/41 passed**. They cover canonicalization, the parser (including XXE refusal and HL7 timestamp edge cases), every document rule, arrival order within a batch, entry-level dedup, the two-batch end-to-end counts, an idempotent replay, and a CSV state round trip across process restarts.
