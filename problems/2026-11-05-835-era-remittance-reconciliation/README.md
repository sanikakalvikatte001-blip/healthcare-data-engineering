# 835 ERA remittance parsing, balancing and claim-to-payment reconciliation (C# / .NET 8)

## Problem

Payers send payment back as an **X12 835 Electronic Remittance Advice (ERA)**. One 835 matches one check or EFT, and it lists every claim that payment covers. For each claim it gives the amount paid and a CAS adjustment for every dollar not paid (contractual write-off, deductible, coinsurance, denial). Before a billing team can auto-post an 835 and close the month, three questions need answers:

1. **Does the file balance?** The X12 implementation guide says charge = paid + adjustments at the service-line and claim level, and the check amount (BPR02) = claim payments − provider-level adjustments (PLB). Payers do send files that don't balance.
2. **Is this a file we already loaded?** Clearinghouses resend files, often under a new name and a new interchange control number. The check trace number (TRN02) is what makes a payment unique.
3. **What happened to each claim we billed?** A claim can be paid, denied, reversed and paid again, reversed and never paid again (the payer took money back), paid on a different charge than we billed (a line was dropped), or never answered. Some remits also come back for claims we can't find in our ledger, which is cash we can't apply.

## Why it matters

- An 835 that doesn't balance and gets auto-posted leaves wrong patient balances and cash that isn't applied. Patient statements go out wrong, and A/R stops tying to the bank deposit.
- Loading a resent file twice counts the same cash twice, so revenue and collections are overstated until someone finds it.
- Reversals that are never re-adjudicated and claims with no remit are lost revenue unless a follow-up queue picks them up. Most payers have timely-filing and appeal deadlines.
- Contractual vs. patient-responsibility splits (CO vs. PR) feed contract-variance and patient-collections reporting.

## Approach

A **reusable C# class library** (`Era835Recon.Core`) with a thin CLI and a test project. There are no NuGet dependencies, only the .NET 8 base class library.

```
src/Era835Recon.Core/
  X12/X12Reader.cs                 tokenizer: reads delimiters from the fixed-width ISA header
  Era/RemittanceModels.cs          Remittance -> ClaimPayment (CLP) -> ServiceLinePayment (SVC) -> Adjustment (CAS)
  Era/Era835Parser.cs              one pass over the segments, tracking the current loop (CAS after SVC = line level)
  Era/BalancingValidator.cs        5 rules from the 005010X221A1 guide -> exceptions table
  Era/Era835Writer.cs              model -> X12 (used for synthetic files and round-trip tests)
  Ledger/ClaimLedger.cs            submitted 837 claims (CLM01 = CLP01 match key)
  Reconciliation/RemitReconciler.cs  dedupe by payer+trace, net reversals, classify each claim
  Synthetic/SyntheticDataGenerator.cs  fixed-seed ledger + four 835 files with planted defects
  Output/CsvExport.cs              warehouse-shaped CSVs
src/Era835Recon.Cli/Program.cs     `generate` and `reconcile` commands, summary report
tests/Era835Recon.Tests/           28 tests (parser, balancing, reconciliation, end-to-end)
```

**Key decisions**

- **Delimiters come from the ISA header.** ISA is always 106 characters, so the element separator is at position 3, the component separator at 104 and the segment terminator at 105. The reader never assumes `* : ~`. A test uses `| >` and newline terminators.
- **Loop context, not segment order.** The 835 is a flat list of segments. A `CAS` belongs to the claim when it follows `CLP`, and to a service line when it follows `SVC`. The parser keeps "current claim / current line" state and raises a `FormatException` for a segment outside its loop.
- **Money is `decimal`,** never `double`, so the balancing rules compare exact values (`240.00 != 235.00`) with no epsilon.
- **Balancing rules** (`BalancingValidator`):

  | Rule | Check | Severity |
  |------|-------|----------|
  | `SVC_LINE_BALANCE` | SVC02 − SVC03 = Σ line CAS | Error |
  | `CLAIM_BALANCE` | CLP03 − CLP04 = Σ claim CAS + Σ line CAS | Error |
  | `CLAIM_LINE_PAID` | CLP04 = Σ SVC03 | Error |
  | `PATIENT_RESP` | CLP05 = Σ PR-group CAS | Warning |
  | `TRANSACTION_BALANCE` | BPR02 = Σ CLP04 − Σ PLB (interest L6 is negative, recoupment WO positive) | Error |

- **Idempotent loads.** A remittance is identified by (payer ID, TRN02 trace number). If the same pair shows up again, that file is skipped and a `DUPLICATE_REMITTANCE` warning is logged. File name and ISA control number don't count.
- **Reversals net out.** A CLP02 = 22 reversal carries negative amounts, so summing every remit for a claim in payment-date order gives the true net paid. The claim's status comes from what happened last.
- **Status precedence**, most urgent first: `UNMATCHED_REMIT` → `NO_REMIT_OVERDUE` / `AWAITING_REMIT` → `OUT_OF_BALANCE` → `CHARGE_MISMATCH` → `REVERSED_NOT_REPAID` → `DENIED` → `REPROCESSED` → `PAID`.
- **Open insurance balance** = billed − net paid − all net adjustments. It should be 0.00 once a claim is final, so any non-zero value is money still to collect or explain.
- **Exit code 2** when error-level exceptions exist, so a scheduler (SQL Agent, ADF, cron) can alert on it.

### Synthetic data (no PHI)

`generate` writes a 40-claim ledger and four 835 files with fixed seed 835. Clean claims are priced at the payer's allowed rate (about 72% commercial, about 58% Medicaid) and split into CO-45, PR-1/2/3 and paid, so they balance. These defects are planted on purpose:

| Claim / file | Planted defect |
|---|---|
| PCN261002 | paid, reversed (CLP02=22), re-adjudicated with $22.50 more |
| PCN261003, PCN261030 | denied (CO-50 not medically necessary; CO-16 missing information) |
| PCN261007 | line CO-45 short by $5.00, so the line and the claim don't balance |
| PCN261012 | reversed, never re-adjudicated |
| PCN261015 | CLP05 overstated by $10 vs. PR adjustments |
| PCN261020 | payer dropped the 36415 venipuncture line ($18) |
| PCN269999 | remit for a claim not in the ledger |
| `era_04_..._resend.835` | exact resend of `era_03` (same payer + trace) |
| PCN261035–1040 | never remitted: 3 past 30 days, 3 within the window |

Provider NPI `1234567893` is the standard test NPI (it passes the Luhn check). Names, member IDs and addresses are placeholders.

## How to run

Requires the .NET 8 SDK (`apt-get install -y dotnet-sdk-8.0`). No package feed is needed: `nuget.config` clears all sources.

```bash
./run.sh                     # build, generate, reconcile, test

# or step by step
dotnet build Era835Recon.sln
dotnet run --project src/Era835Recon.Cli -- generate  --data data
dotnet run --project src/Era835Recon.Cli -- reconcile --data data --out output --as-of 2026-11-05 --follow-up-days 30
dotnet run --project tests/Era835Recon.Tests
```

Outputs in `output/`: `remit_claims.csv` (38 CLP loops), `remit_adjustments.csv` (144 CAS rows), `exceptions.csv`, `reconciliation.csv` (one row per claim) and `summary.txt`.

> **Note on tests:** the test project uses a small built-in runner (`TestRunner.cs`) with xUnit-style `[Fact]` methods and `Assert.Equal/True/Single/Throws`. The sandbox this was built in couldn't reach nuget.org, so the xunit packages couldn't be restored. The test code reads like xUnit and moves over by swapping the runner for the xunit packages.

## Results

Real output from `./run.sh`, as of 2026-11-05:

```
Ledger claims (837 submitted) : 40
835 transactions parsed       : 4
835 transactions accepted     : 3 (duplicates skipped: 1)
Claim payment loops (CLP)     : 38

Payments by check/EFT
  EFT0091500001   99001   15 claims  BPR02   1,848.52  PLB    -3.42
  EFT0100600002   99001   14 claims  BPR02   1,326.97  PLB     0.00
  CHK0000778812   99002    9 claims  BPR02   1,027.41  PLB    40.00

Claim status                 claims      billed    net paid   open ins bal
  PAID                         28    7,301.00    3,759.05           0.00
  DENIED                        2      601.00        0.00           0.00
  REPROCESSED                   1      191.00      130.05           0.00
  REVERSED_NOT_REPAID           1      315.00        0.00         315.00
  OUT_OF_BALANCE                1      320.00      185.25           5.00
  CHARGE_MISMATCH               1      185.00       96.98          18.00
  AWAITING_REMIT                3      714.00        0.00         714.00
  NO_REMIT_OVERDUE              3      601.00        0.00         601.00
  UNMATCHED_REMIT               1        0.00       68.15           0.00
  TOTAL                        41   10,228.00    4,239.48       1,653.00

Adjustment mix (ledger claims): contractual 3,103.13 | patient resp 1,300.54 | other 0.00

Exceptions
  [Warning] DUPLICATE_REMITTANCE            Trace CHK0000778812 from payer 99002 already loaded; file skipped (9 claims).
  [Error  ] SVC_LINE_BALANCE     PCN261007  Line 99396: charge 240.00 != paid 140.16 + adjustments 94.84
  [Error  ] CLAIM_BALANCE        PCN261007  Charge 320.00 != paid 185.25 + adjustments 129.75
  [Warning] PATIENT_RESP         PCN261015  CLP05 35.00 != PR adjustments 25.00

28/28 tests passed
```

What the numbers show:

- **Every planted defect was found, and nothing else was flagged.** The end-to-end test asserts the exact set of four exceptions and the status of each planted claim.
- **All 28 PAID claims have a 0.00 open balance**, so every dollar billed is explained by payment, CO or PR.
- **$1,653.00 is still open with insurance.** $315.00 is a reversal that was never re-adjudicated, $5.00 is an 835 that doesn't balance, $18.00 is a dropped line to appeal, and $1,315.00 is six claims with no remit. Three of those ($601.00) are past the 30-day follow-up window.
- **Skipping the resent file avoided double-counting $1,027.41** of Medicaid cash.
- **$68.15 arrived for claim PCN269999, which has no 837 in the ledger.** It should go to an unapplied-cash queue, not be posted.
- All three accepted checks tie out: BPR02 = Σ CLP04 − Σ PLB, including −$3.42 prompt-pay interest and a $40.00 overpayment recoupment.
