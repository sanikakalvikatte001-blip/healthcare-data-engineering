using Era835Recon.Core.Era;
using Era835Recon.Core.Ledger;
using Era835Recon.Core.Output;
using Era835Recon.Core.Reconciliation;
using Era835Recon.Core.Synthetic;

namespace Era835Recon.Tests;

public class BalancingValidatorTests
{
    private static Remittance Parse(string raw) => Era835Parser.Parse(raw, "t.835").Single();

    [Fact]
    public void Balanced_claim_produces_no_exceptions() =>
        Assert.Empty(BalancingValidator.Validate(Parse(Sample835.BalancedClaim())));

    [Fact]
    public void Line_adjustment_short_by_five_fails_line_and_claim_balance()
    {
        var raw = Sample835.BalancedClaim().Replace("CAS*CO*45*30~", "CAS*CO*45*25~");
        var issues = BalancingValidator.Validate(Parse(raw));

        var line = Assert.Single(issues.Where(i => i.Rule == BalancingValidator.ServiceLineBalance));
        var claim = Assert.Single(issues.Where(i => i.Rule == BalancingValidator.ClaimBalance));
        Assert.Equal(-5m, line.Difference);
        Assert.Equal(-5m, claim.Difference);
        Assert.Equal(Severity.Error, claim.Severity);
    }

    [Fact]
    public void Check_amount_that_does_not_match_claim_payments_fails_transaction_balance()
    {
        var issue = Assert.Single(BalancingValidator.Validate(Parse(Sample835.BalancedClaim(bpr02: "119.50"))));
        Assert.Equal(BalancingValidator.TransactionBalance, issue.Rule);
        Assert.Equal(120m, issue.Expected);
        Assert.Equal(119.50m, issue.Actual);
    }

    [Fact]
    public void Plb_interest_increases_and_recoupment_decreases_the_expected_check()
    {
        // 120 claim payment, -3.42 interest (paid to provider), +40 recoupment (taken back) => 83.42
        var raw = Sample835.BalancedClaim(bpr02: "83.42")
            .Replace("SE*", "PLB*1234567893*20261231*L6*-3.42*WO:OLD77*40~\r\nSE*");
        Assert.Empty(BalancingValidator.Validate(Parse(raw)));
    }

    [Fact]
    public void Patient_responsibility_header_mismatch_is_a_warning_only()
    {
        var raw = Sample835.BalancedClaim().Replace("CLP*PCN1*1*200*120*40*", "CLP*PCN1*1*200*120*50*");
        var issue = Assert.Single(BalancingValidator.Validate(Parse(raw)));
        Assert.Equal(BalancingValidator.PatientResponsibility, issue.Rule);
        Assert.Equal(Severity.Warning, issue.Severity);
    }
}

public class RemitReconcilerTests
{
    private static readonly DateOnly AsOf = new(2026, 11, 5);
    private static SubmittedClaim Ledger(string id, decimal billed = 200m, int daysAgo = 40) =>
        new(id, "99001", "SYN000001", AsOf.AddDays(-daysAgo - 3), AsOf.AddDays(-daysAgo), billed, 2);

    private static Remittance Remit(string raw, string file = "t.835") => Era835Parser.Parse(raw, file).Single();

    private static string Reversal(string pcn, string trace) => Sample835.Wrap(
        "BPR*I*-120*C*ACH*CCP*01*999999999*DA*123456*1512345678**01*999988880*DA*98765*20261015",
        $"TRN*1*{trace}*1512345678", "N1*PR*SYNTHETIC HEALTH PLAN*XV*99001",
        $"CLP*{pcn}*22*-200*-120*-40*12*ICN0001*11*1",
        "SVC*HC:99213*-200*-120**1", "CAS*CO*45*-40", "CAS*PR*3*-40");

    [Fact]
    public void Balanced_payment_matching_the_ledger_is_paid_with_zero_open_balance()
    {
        var row = new RemitReconciler(AsOf).Reconcile(new[] { Ledger("PCN1") },
            new[] { Remit(Sample835.BalancedClaim()) }).Rows.Single();
        Assert.Equal(ReconStatus.Paid, row.Status);
        Assert.Equal(0m, row.OpenInsuranceBalance);
        Assert.Equal(40m, row.NetContractualAdjustment);
        Assert.Equal(40m, row.NetPatientResponsibility);
    }

    [Fact]
    public void Resent_file_with_same_payer_and_trace_is_skipped_not_double_counted()
    {
        var result = new RemitReconciler(AsOf).Reconcile(new[] { Ledger("PCN1") },
            new[] { Remit(Sample835.BalancedClaim(), "a.835"), Remit(Sample835.BalancedClaim(), "a_resend.835") });

        Assert.Equal(1, result.AcceptedRemittances.Count);
        Assert.Equal(120m, result.Rows.Single().NetPaid);
        Assert.Equal("DUPLICATE_REMITTANCE", Assert.Single(result.Exceptions).Rule);
    }

    [Fact]
    public void Reversal_without_readjudication_leaves_the_full_charge_open()
    {
        var row = new RemitReconciler(AsOf).Reconcile(new[] { Ledger("PCN1") },
            new[] { Remit(Sample835.BalancedClaim()), Remit(Reversal("PCN1", "EFT0002")) }).Rows.Single();
        Assert.Equal(ReconStatus.ReversedNotRepaid, row.Status);
        Assert.Equal(0m, row.NetPaid);
        Assert.Equal(200m, row.OpenInsuranceBalance);
    }

    [Fact]
    public void Reversal_followed_by_new_payment_is_reprocessed()
    {
        var corrected = Sample835.BalancedClaim().Replace("TRN*1*EFT0001", "TRN*1*EFT0003")
            .Replace("20261001~", "20261020~");
        var row = new RemitReconciler(AsOf).Reconcile(new[] { Ledger("PCN1") }, new[]
        {
            Remit(Sample835.BalancedClaim()), Remit(Reversal("PCN1", "EFT0002")), Remit(corrected),
        }).Rows.Single();
        Assert.Equal(ReconStatus.Reprocessed, row.Status);
        Assert.Equal(3, row.RemitCount);
        Assert.Equal(120m, row.NetPaid);
        Assert.Equal(0m, row.OpenInsuranceBalance);
    }

    [Fact]
    public void Claims_without_remits_are_split_by_follow_up_window()
    {
        var rows = new RemitReconciler(AsOf, followUpDays: 30).Reconcile(
            new[] { Ledger("OLD", daysAgo: 31), Ledger("NEW", daysAgo: 30) }, Array.Empty<Remittance>()).Rows;
        Assert.Equal(ReconStatus.NoRemitOverdue, rows.Single(r => r.ClaimId == "OLD").Status);
        Assert.Equal(ReconStatus.AwaitingRemit, rows.Single(r => r.ClaimId == "NEW").Status);
    }

    [Fact]
    public void Remit_for_unknown_claim_is_reported_as_unmatched_cash()
    {
        var row = new RemitReconciler(AsOf).Reconcile(Array.Empty<SubmittedClaim>(),
            new[] { Remit(Sample835.BalancedClaim(pcn: "PCN404")) }).Rows.Single();
        Assert.Equal(ReconStatus.UnmatchedRemit, row.Status);
        Assert.Equal(120m, row.NetPaid);
    }

    [Fact]
    public void Adjudicated_charge_different_from_billed_is_a_charge_mismatch()
    {
        var row = new RemitReconciler(AsOf).Reconcile(new[] { Ledger("PCN1", billed: 218m) },
            new[] { Remit(Sample835.BalancedClaim()) }).Rows.Single();
        Assert.Equal(ReconStatus.ChargeMismatch, row.Status);
        Assert.Equal(18m, row.OpenInsuranceBalance);
    }

    [Fact]
    public void Status_codes_are_exported_in_upper_snake_case() =>
        Assert.Equal("REVERSED_NOT_REPAID", CsvExport.ToSnake(ReconStatus.ReversedNotRepaid));
}

/// <summary>End-to-end on the synthetic dataset: every planted defect is found, nothing else is.</summary>
public class SyntheticEndToEndTests
{
    private readonly ReconciliationResult _result;

    public SyntheticEndToEndTests()
    {
        var data = new SyntheticDataGenerator(seed: 835).Generate();
        var remits = data.EraFiles.SelectMany(f => Era835Parser.Parse(f.Content, f.FileName)).ToList();
        _result = new RemitReconciler(SyntheticDataGenerator.AsOfDate).Reconcile(data.Ledger, remits);
    }

    private ReconStatus StatusOf(string id) => _result.Rows.Single(r => r.ClaimId == id).Status;

    [Fact]
    public void Every_planted_defect_gets_the_expected_status()
    {
        Assert.Equal(ReconStatus.Reprocessed, StatusOf("PCN261002"));
        Assert.Equal(ReconStatus.Denied, StatusOf("PCN261003"));
        Assert.Equal(ReconStatus.OutOfBalance, StatusOf("PCN261007"));
        Assert.Equal(ReconStatus.ReversedNotRepaid, StatusOf("PCN261012"));
        Assert.Equal(ReconStatus.ChargeMismatch, StatusOf("PCN261020"));
        Assert.Equal(ReconStatus.Denied, StatusOf("PCN261030"));
        Assert.Equal(ReconStatus.UnmatchedRemit, StatusOf("PCN269999"));
        foreach (var id in new[] { "PCN261035", "PCN261036", "PCN261037" }) Assert.Equal(ReconStatus.NoRemitOverdue, StatusOf(id));
        foreach (var id in new[] { "PCN261038", "PCN261039", "PCN261040" }) Assert.Equal(ReconStatus.AwaitingRemit, StatusOf(id));
    }

    [Fact]
    public void All_other_claims_are_paid_and_fully_explained()
    {
        var paid = _result.Rows.Where(r => r.Status == ReconStatus.Paid).ToList();
        Assert.Equal(28, paid.Count);
        Assert.True(paid.All(r => r.OpenInsuranceBalance == 0m), "A PAID claim still has an open insurance balance");
    }

    [Fact]
    public void Exceptions_are_exactly_the_planted_ones()
    {
        var found = _result.Exceptions.Select(e => $"{e.Rule}:{e.PatientControlNumber}").OrderBy(s => s).ToList();
        Assert.Equal(string.Join(",", new[]
        {
            "CLAIM_BALANCE:PCN261007", "DUPLICATE_REMITTANCE:", "PATIENT_RESP:PCN261015", "SVC_LINE_BALANCE:PCN261007",
        }), string.Join(",", found));
    }

    [Fact]
    public void Every_accepted_check_ties_to_its_claim_payments()
    {
        Assert.Equal(3, _result.AcceptedRemittances.Count);
        Assert.True(_result.Exceptions.All(e => e.Rule != BalancingValidator.TransactionBalance));
    }
}
