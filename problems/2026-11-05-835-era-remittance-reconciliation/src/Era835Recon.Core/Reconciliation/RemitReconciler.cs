using Era835Recon.Core.Ledger;
using Era835Recon.Core.Era;

namespace Era835Recon.Core.Reconciliation;

/// <summary>Where a submitted claim stands once every 835 received so far is applied.</summary>
public enum ReconStatus
{
    Paid,                 // processed with a payment, balanced
    Denied,               // latest adjudication is CLP02 = 4
    Reprocessed,          // reversed (CLP02 = 22) and re-adjudicated by the payer
    ReversedNotRepaid,    // payer took the money back and has not re-adjudicated (recoupment risk)
    OutOfBalance,         // 835 math does not tie out; cannot auto-post
    ChargeMismatch,       // payer adjudicated a different billed amount than we sent
    AwaitingRemit,        // no 835 yet, still inside the follow-up window
    NoRemitOverdue,       // no 835 and past the follow-up window: work the claim
    UnmatchedRemit,       // 835 claim with no matching 837 in our ledger (cash we cannot apply)
}

/// <summary>One output row per claim: the claim-level reconciliation fact.</summary>
public sealed record ReconciliationRow(
    string ClaimId,
    string PayerId,
    ReconStatus Status,
    decimal BilledAmount,
    int RemitCount,
    decimal NetPaid,
    decimal NetContractualAdjustment,   // CO group: write-off per contract
    decimal NetPatientResponsibility,   // PR group: moves to patient A/R
    decimal NetOtherAdjustment,         // OA / PI / CR groups
    decimal OpenInsuranceBalance,       // billed - paid - all adjustments; should be 0 when finalized
    int? DaysSinceSubmission,
    string Detail);

public sealed record ReconciliationResult(
    IReadOnlyList<ReconciliationRow> Rows,
    IReadOnlyList<BalancingException> Exceptions,
    IReadOnlyList<Remittance> AcceptedRemittances);

/// <summary>
/// Matches 835 claim payments to the 837 claims we submitted, keyed on the patient control
/// number (CLM01 = CLP01), and classifies every claim. Steps:
///   1. Drop resent files: the same payer + TRN02 trace number is the same check, so posting it
///      twice would double-count cash.
///   2. Run the balancing rules on each accepted remittance.
///   3. Net every remit per claim (reversals carry negative amounts, so they cancel the original).
///   4. Classify each ledger claim, then list remits that match nothing in the ledger.
/// </summary>
public sealed class RemitReconciler
{
    private readonly DateOnly _asOfDate;
    private readonly int _followUpDays;

    public RemitReconciler(DateOnly asOfDate, int followUpDays = 30)
    {
        _asOfDate = asOfDate;
        _followUpDays = followUpDays;
    }

    public ReconciliationResult Reconcile(IEnumerable<SubmittedClaim> ledger, IEnumerable<Remittance> remittances)
    {
        var exceptions = new List<BalancingException>();

        // Step 1: de-duplicate by (payer, trace number), keep the first file received.
        var accepted = new List<Remittance>();
        var seenTraces = new HashSet<(string, string)>();
        foreach (var remit in remittances)
        {
            if (seenTraces.Add((remit.PayerId, remit.TraceNumber))) { accepted.Add(remit); continue; }

            exceptions.Add(new BalancingException(Severity.Warning, "DUPLICATE_REMITTANCE", remit.SourceFile,
                remit.TraceNumber, "", 0m, remit.TotalPaymentAmount,
                $"Trace {remit.TraceNumber} from payer {remit.PayerId} already loaded; file skipped ({remit.Claims.Count} claims)."));
        }

        // Step 2: balancing rules.
        foreach (var remit in accepted) exceptions.AddRange(BalancingValidator.Validate(remit));
        var outOfBalanceClaims = exceptions
            .Where(e => e.Severity == Severity.Error && e.PatientControlNumber != "")
            .Select(e => e.PatientControlNumber)
            .ToHashSet();

        // Step 3: every claim payment in received order (payment date, then file order).
        var paymentsByClaim = accepted
            .OrderBy(r => r.PaymentDate)
            .SelectMany(r => r.Claims)
            .ToLookup(c => c.PatientControlNumber);

        // Step 4a: classify ledger claims.
        var rows = new List<ReconciliationRow>();
        var ledgerIds = new HashSet<string>();
        foreach (var claim in ledger)
        {
            ledgerIds.Add(claim.ClaimId);
            var payments = paymentsByClaim[claim.ClaimId].ToList();
            rows.Add(BuildRow(claim.ClaimId, claim.PayerId, claim.BilledAmount, claim.SubmittedDate,
                payments, outOfBalanceClaims.Contains(claim.ClaimId), inLedger: true));
        }

        // Step 4b: remits with no ledger match.
        foreach (var group in paymentsByClaim.Where(g => !ledgerIds.Contains(g.Key)))
        {
            var payments = group.ToList();
            rows.Add(BuildRow(group.Key, payments[0].PayerId, 0m, null, payments,
                outOfBalanceClaims.Contains(group.Key), inLedger: false));
        }

        return new ReconciliationResult(rows, exceptions, accepted);
    }

    private ReconciliationRow BuildRow(string claimId, string payerId, decimal billed, DateOnly? submitted,
        List<ClaimPayment> payments, bool outOfBalance, bool inLedger)
    {
        int? daysOut = submitted is null ? null : _asOfDate.DayNumber - submitted.Value.DayNumber;
        var adjustments = payments.SelectMany(p => p.AllAdjustments).ToList();

        decimal netPaid = payments.Sum(p => p.PaidAmount);
        decimal co = adjustments.Where(a => a.GroupCode == "CO").Sum(a => a.Amount);
        decimal pr = adjustments.Where(a => a.GroupCode == "PR").Sum(a => a.Amount);
        decimal other = adjustments.Where(a => a.GroupCode is not ("CO" or "PR")).Sum(a => a.Amount);
        decimal open = inLedger ? billed - netPaid - co - pr - other : 0m;

        var latest = payments.LastOrDefault();
        var original = payments.Where(p => !p.IsReversal).ToList();
        bool hasReversal = payments.Any(p => p.IsReversal);

        // Order matters: the most actionable problem wins.
        (ReconStatus status, string detail) = true switch
        {
            _ when !inLedger => (ReconStatus.UnmatchedRemit,
                $"No 837 found for CLP01 {claimId}; {netPaid:0.00} paid on trace {latest!.TraceNumber}"),
            _ when payments.Count == 0 && daysOut > _followUpDays => (ReconStatus.NoRemitOverdue,
                $"No 835 after {daysOut} days (follow-up window {_followUpDays})"),
            _ when payments.Count == 0 => (ReconStatus.AwaitingRemit, $"Submitted {daysOut} days ago"),
            _ when outOfBalance => (ReconStatus.OutOfBalance,
                $"835 does not balance; {open:0.00} unexplained"),
            _ when original.Any(p => p.ChargeAmount != billed) => (ReconStatus.ChargeMismatch,
                $"Payer adjudicated {original.First(p => p.ChargeAmount != billed).ChargeAmount:0.00} vs billed {billed:0.00}"),
            _ when latest!.IsReversal => (ReconStatus.ReversedNotRepaid,
                $"Reversed on trace {latest.TraceNumber}; net paid {netPaid:0.00}"),
            _ when latest!.IsDenied => (ReconStatus.Denied,
                "Denied: " + string.Join(";", latest.AllAdjustments.Select(a => $"{a.GroupCode}-{a.ReasonCode}").Distinct())),
            _ when hasReversal => (ReconStatus.Reprocessed,
                $"Reversed and re-adjudicated across {payments.Count} remits; net paid {netPaid:0.00}"),
            _ => (ReconStatus.Paid, ""),
        };

        return new ReconciliationRow(claimId, payerId, status, billed, payments.Count,
            netPaid, co, pr, other, open, daysOut, detail);
    }
}
