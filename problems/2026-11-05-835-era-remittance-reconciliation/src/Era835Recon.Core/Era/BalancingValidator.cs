namespace Era835Recon.Core.Era;

public enum Severity { Warning, Error }

/// <summary>A row for the exceptions table: which rule failed, where, and by how much.</summary>
public sealed record BalancingException(
    Severity Severity,
    string Rule,
    string SourceFile,
    string TraceNumber,
    string PatientControlNumber,
    decimal Expected,
    decimal Actual,
    string Message)
{
    public decimal Difference => Actual - Expected;
}

/// <summary>
/// Applies the 835 balancing rules from the X12 implementation guide (005010X221A1, section 1.10.2).
/// An 835 that does not balance cannot be auto-posted: the billing system would either
/// post the wrong patient balance or leave cash unapplied. Catching it at load time lets
/// the team call the payer before month-end close instead of after.
/// </summary>
public static class BalancingValidator
{
    public const string ServiceLineBalance = "SVC_LINE_BALANCE";      // SVC02 - SVC03 = line CAS
    public const string ClaimBalance = "CLAIM_BALANCE";               // CLP03 - CLP04 = claim + line CAS
    public const string ClaimLinePaid = "CLAIM_LINE_PAID";            // CLP04 = sum(SVC03)
    public const string PatientResponsibility = "PATIENT_RESP";      // CLP05 = sum(PR adjustments)
    public const string TransactionBalance = "TRANSACTION_BALANCE";   // BPR02 = sum(CLP04) - sum(PLB)

    public static IReadOnlyList<BalancingException> Validate(Remittance remit)
    {
        var issues = new List<BalancingException>();

        foreach (var claim in remit.Claims)
        {
            void Add(Severity sev, string rule, decimal expected, decimal actual, string msg) =>
                issues.Add(new BalancingException(sev, rule, remit.SourceFile, remit.TraceNumber,
                    claim.PatientControlNumber, expected, actual, msg));

            // 1. Each service line: what was billed minus what was paid must be explained by line adjustments.
            foreach (var line in claim.ServiceLines)
            {
                var explained = line.PaidAmount + line.AdjustmentTotal;
                if (explained != line.ChargeAmount)
                    Add(Severity.Error, ServiceLineBalance, line.ChargeAmount, explained,
                        $"Line {line.ProcedureCode}: charge {line.ChargeAmount:0.00} != paid {line.PaidAmount:0.00} + adjustments {line.AdjustmentTotal:0.00}");
            }

            // 2. Whole claim: charge = paid + every adjustment (claim level and line level).
            var claimExplained = claim.PaidAmount + claim.AllAdjustments.Sum(a => a.Amount);
            if (claimExplained != claim.ChargeAmount)
                Add(Severity.Error, ClaimBalance, claim.ChargeAmount, claimExplained,
                    $"Charge {claim.ChargeAmount:0.00} != paid {claim.PaidAmount:0.00} + adjustments {claimExplained - claim.PaidAmount:0.00}");

            // 3. Claim paid must equal the sum of its line payments (when lines are reported).
            if (claim.ServiceLines.Count > 0)
            {
                var linePaid = claim.ServiceLines.Sum(l => l.PaidAmount);
                if (linePaid != claim.PaidAmount)
                    Add(Severity.Error, ClaimLinePaid, claim.PaidAmount, linePaid,
                        $"CLP04 {claim.PaidAmount:0.00} != sum of SVC03 {linePaid:0.00}");
            }

            // 4. Patient responsibility header should match PR-group adjustments (drives patient statements).
            var prTotal = claim.AllAdjustments.Where(a => a.GroupCode == "PR").Sum(a => a.Amount);
            if (prTotal != claim.PatientResponsibility)
                Add(Severity.Warning, PatientResponsibility, claim.PatientResponsibility, prTotal,
                    $"CLP05 {claim.PatientResponsibility:0.00} != PR adjustments {prTotal:0.00}");
        }

        // 5. The check/EFT amount must equal claim payments less provider-level adjustments.
        var expectedPayment = remit.Claims.Sum(c => c.PaidAmount) - remit.ProviderAdjustments.Sum(p => p.Amount);
        if (expectedPayment != remit.TotalPaymentAmount)
            issues.Add(new BalancingException(Severity.Error, TransactionBalance, remit.SourceFile, remit.TraceNumber,
                "", expectedPayment, remit.TotalPaymentAmount,
                $"BPR02 {remit.TotalPaymentAmount:0.00} != sum(CLP04) - sum(PLB) = {expectedPayment:0.00}"));

        return issues;
    }
}
