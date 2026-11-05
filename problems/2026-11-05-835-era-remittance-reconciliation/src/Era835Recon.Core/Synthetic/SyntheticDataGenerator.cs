using Era835Recon.Core.Era;
using Era835Recon.Core.Ledger;

namespace Era835Recon.Core.Synthetic;

/// <summary>
/// Builds a fully synthetic claims ledger and four 835 files (no real PHI, fixed seed).
/// The data is clean by default, then a handful of realistic problems are planted on purpose
/// so the reconciliation has something to find:
///   PCN261002  reversed (CLP02=22) and re-adjudicated with a higher payment in a later 835
///   PCN261003  denied, CO-50 (not medically necessary)
///   PCN261007  line CO-45 short by 5.00, so the line and claim do not balance
///   PCN261012  reversed and never re-adjudicated (recoupment, money taken back)
///   PCN261015  CLP05 patient responsibility does not match its PR adjustments
///   PCN261020  payer dropped the venipuncture line, adjudicated charge != billed charge
///   PCN269999  remit for a claim that is not in our ledger
///   PCN261030  Medicaid denial, CO-16 (missing information)
///   era_04     exact resend of era_03 (same payer + trace number)
///   PCN261035..1040  never remitted (three overdue, three still in the follow-up window)
/// </summary>
public sealed class SyntheticDataGenerator
{
    public const string ProviderNpi = "1234567893";   // well-known test NPI that passes the Luhn check
    public const string ProviderName = "SYNTHETIC FAMILY CLINIC";
    public static readonly DateOnly AsOfDate = new(2026, 11, 5);

    private static readonly (string Id, string Name, decimal AllowedRate)[] Payers =
    {
        ("99001", "SYNTHETIC HEALTH PLAN", 0.72m),
        ("99002", "DEMO STATE MEDICAID", 0.58m),
    };

    // Clinic fee schedule (billed charges), office-visit centric.
    private static readonly (string Cpt, decimal Charge)[] FeeSchedule =
    {
        ("99213", 135.00m), ("99214", 195.00m), ("99396", 240.00m),
        ("80053", 62.00m), ("85025", 38.00m), ("93000", 75.00m), ("90471", 32.00m),
    };
    private const string Venipuncture = "36415";
    private const decimal VenipunctureCharge = 18.00m;

    private readonly Random _rng;

    public SyntheticDataGenerator(int seed = 835) => _rng = new Random(seed);

    public sealed record Output(IReadOnlyList<SubmittedClaim> Ledger, IReadOnlyList<(string FileName, string Content)> EraFiles);

    public Output Generate()
    {
        // ---- 1. Ledger: 40 submitted professional claims --------------------------------------
        var ledger = new List<SubmittedClaim>();
        var lines = new Dictionary<string, List<(string Cpt, decimal Charge, DateOnly Dos)>>();
        var members = new Dictionary<string, string>();

        for (int n = 1; n <= 40; n++)
        {
            string pcn = $"PCN26{1000 + n}";
            var payer = n <= 25 ? Payers[0] : Payers[1];
            // Service dates are staggered so each claim is paid after it was seen.
            var windowStart = n <= 15 ? new DateOnly(2026, 8, 17) : n <= 25 ? new DateOnly(2026, 9, 1) : new DateOnly(2026, 9, 10);
            var dos = windowStart.AddDays(_rng.Next(0, 20));
            var submitted = dos.AddDays(_rng.Next(2, 6));

            // Unremitted claims: 35-37 are old (overdue), 38-40 were sent within the last two weeks.
            if (n is >= 35 and <= 37) submitted = AsOfDate.AddDays(-_rng.Next(45, 70));
            if (n >= 38) submitted = AsOfDate.AddDays(-_rng.Next(3, 14));
            if (n >= 35) dos = submitted.AddDays(-3);

            // Every visit has an E&M code, plus 0-2 ancillaries; lab draws add venipuncture.
            var claimLines = new List<(string, decimal, DateOnly)> { Pick(0, 3, dos) };
            int extras = n == 20 ? 1 : _rng.Next(0, 3);
            for (int i = 0; i < extras; i++) claimLines.Add(Pick(3, FeeSchedule.Length, dos));
            if (n == 20 || claimLines.Any(l => l.Item1 is "80053" or "85025"))
                claimLines.Add((Venipuncture, VenipunctureCharge, dos));
            claimLines = claimLines.DistinctBy(l => l.Item1).ToList();

            lines[pcn] = claimLines;
            members[pcn] = $"SYN{_rng.Next(100000, 999999)}";
            ledger.Add(new SubmittedClaim(pcn, payer.Id, members[pcn], dos, submitted,
                claimLines.Sum(l => l.Item2), claimLines.Count));
        }

        // ---- 2. 835 files ----------------------------------------------------------------------
        ClaimPayment Adjudicate(int n, string status = "1") =>
            BuildClaimPayment($"PCN26{1000 + n}", n <= 25 ? Payers[0] : Payers[1], lines[$"PCN26{1000 + n}"], status,
                members[$"PCN26{1000 + n}"]);

        // era_01: commercial payer, claims 1-15, with prompt-pay interest (PLB L6, negative = paid to us).
        var era1 = NewRemit("era_01_99001_20260915.835", Payers[0], "EFT0091500001", new DateOnly(2026, 9, 15));
        for (int n = 1; n <= 15; n++) era1.Claims.Add(Adjudicate(n, n == 3 ? "4" : "1"));
        Corrupt_LineAdjustmentShort(era1.Claims.Single(c => c.PatientControlNumber == "PCN261007"), 5.00m);
        Corrupt_PatientRespHeader(era1, "PCN261015", 10.00m);
        era1.ProviderAdjustments.Add(new ProviderAdjustment("L6", "PCN261009", -3.42m));

        // era_02: commercial payer, claims 16-25 + reversal/correction of 1002 + reversal of 1012 + unknown claim.
        var era2 = NewRemit("era_02_99001_20261006.835", Payers[0], "EFT0100600002", new DateOnly(2026, 10, 6));
        for (int n = 16; n <= 25; n++) era2.Claims.Add(Adjudicate(n));
        DropLine(era2.Claims.Single(c => c.PatientControlNumber == "PCN261020"), Venipuncture, era2);
        var original1002 = era1.Claims.Single(c => c.PatientControlNumber == "PCN261002");
        era2.Claims.Add(Reverse(original1002));
        era2.Claims.Add(Readjudicate(original1002, extraPaid: 22.50m));
        era2.Claims.Add(Reverse(era1.Claims.Single(c => c.PatientControlNumber == "PCN261012")));
        var stray = BuildClaimPayment("PCN269999", Payers[0],
            new() { ("99213", 135.00m, new DateOnly(2026, 9, 20)) }, "1", "SYN000000", costShareOverride: 0);
        era2.Claims.Add(stray);

        // era_03: Medicaid, claims 26-34, one denial and an overpayment recovery (PLB WO, positive = taken back).
        var era3 = NewRemit("era_03_99002_20261020.835", Payers[1], "CHK0000778812", new DateOnly(2026, 10, 20));
        for (int n = 26; n <= 34; n++) era3.Claims.Add(Adjudicate(n, n == 30 ? "4" : "1"));
        era3.ProviderAdjustments.Add(new ProviderAdjustment("WO", "PCN260871", 40.00m));

        foreach (var r in new[] { era1, era2, era3 })
        {
            foreach (var c in r.Claims) { c.TraceNumber = r.TraceNumber; c.PayerId = r.PayerId; }
            r.TotalPaymentAmount = r.Claims.Sum(c => c.PaidAmount) - r.ProviderAdjustments.Sum(p => p.Amount);
        }

        var created = new DateTime(2026, 11, 5, 6, 0, 0);
        var files = new List<(string, string)>
        {
            (era1.SourceFile, Era835Writer.Write(era1, 101, created)),
            (era2.SourceFile, Era835Writer.Write(era2, 102, created)),
            (era3.SourceFile, Era835Writer.Write(era3, 103, created)),
            // Clearinghouse resent era_03 under a new file name and interchange number.
            ("era_04_99002_20261021_resend.835", Era835Writer.Write(era3, 104, created.AddDays(-15))),
        };
        return new Output(ledger, files);
    }

    // ---- adjudication helpers -------------------------------------------------------------------

    private (string, decimal, DateOnly) Pick(int from, int to, DateOnly dos)
    {
        var f = FeeSchedule[_rng.Next(from, to)];
        return (f.Cpt, f.Charge, dos);
    }

    private static Remittance NewRemit(string file, (string Id, string Name, decimal Rate) payer, string trace, DateOnly paid) =>
        new()
        {
            SourceFile = file, TraceNumber = trace, PaymentMethod = trace.StartsWith("CHK") ? "CHK" : "ACH",
            PaymentDate = paid, PayerId = payer.Id, PayerName = payer.Name,
            PayeeName = ProviderName, PayeeNpi = ProviderNpi,
        };

    /// <summary>
    /// Prices each line at the payer's allowed rate and splits allowed into paid + patient share.
    /// Charge = paid + CO-45 (contractual) + PR (deductible/coinsurance/copay), so clean claims balance.
    /// </summary>
    private ClaimPayment BuildClaimPayment(string pcn, (string Id, string Name, decimal Rate) payer,
        List<(string Cpt, decimal Charge, DateOnly Dos)> claimLines, string status, string memberId,
        int? costShareOverride = null)
    {
        bool medicaid = payer.Id == "99002";
        // Commercial cost share for the visit: copay, coinsurance, or deductible.
        int costShare = medicaid ? -1 : _rng.Next(0, 3);
        if (costShareOverride is { } forced) costShare = forced;
        var claim = new ClaimPayment
        {
            PatientControlNumber = pcn, StatusCode = status, ChargeAmount = claimLines.Sum(l => l.Charge),
            PaidAmount = 0, PatientResponsibility = 0,
            PayerClaimControlNumber = $"{payer.Id}{_rng.Next(10_000_000, 99_999_999)}",
            PatientMemberId = memberId, StatementFromDate = claimLines[0].Dos,
        };

        foreach (var (cpt, charge, dos) in claimLines)
        {
            ServiceLinePayment line;
            if (status == "4")
            {
                // Denied: whole charge is a contractual adjustment, nothing paid.
                line = new ServiceLinePayment { ProcedureCode = cpt, ChargeAmount = charge, PaidAmount = 0 };
                line.Adjustments.Add(new Adjustment("CO", medicaid ? "16" : "50", charge));
            }
            else
            {
                decimal allowed = Math.Round(charge * (payer.Rate + _rng.Next(-3, 4) / 100m), 2);
                decimal patient = 0m; string reason = "";
                bool isEm = cpt.StartsWith("992") || cpt.StartsWith("993");
                if (costShare == 0 && isEm) { patient = Math.Min(25m, allowed); reason = "3"; }        // copay
                if (costShare == 1) { patient = Math.Round(allowed * 0.20m, 2); reason = "2"; }       // coinsurance
                if (costShare == 2 && isEm) { patient = allowed; reason = "1"; }                      // deductible

                line = new ServiceLinePayment { ProcedureCode = cpt, ChargeAmount = charge, PaidAmount = allowed - patient };
                line.Adjustments.Add(new Adjustment("CO", "45", charge - allowed));
                if (patient > 0) line.Adjustments.Add(new Adjustment("PR", reason, patient));
            }
            line.ServiceDate = dos;
            claim.ServiceLines.Add(line);
        }

        return WithTotals(claim);
    }

    /// <summary>Recomputes CLP04/CLP05 from the lines (they are init-only, so this returns a copy).</summary>
    private static ClaimPayment WithTotals(ClaimPayment c, decimal? chargeOverride = null)
    {
        var copy = new ClaimPayment
        {
            PatientControlNumber = c.PatientControlNumber, StatusCode = c.StatusCode,
            ChargeAmount = chargeOverride ?? c.ServiceLines.Sum(l => l.ChargeAmount),
            PaidAmount = c.ServiceLines.Sum(l => l.PaidAmount),
            PatientResponsibility = c.AllAdjustments.Where(a => a.GroupCode == "PR").Sum(a => a.Amount),
            PayerClaimControlNumber = c.PayerClaimControlNumber, PatientMemberId = c.PatientMemberId,
            StatementFromDate = c.StatementFromDate,
        };
        copy.Adjustments.AddRange(c.Adjustments);
        copy.ServiceLines.AddRange(c.ServiceLines);
        return copy;
    }

    /// <summary>Reversal: same claim, CLP02 = 22, every amount negated so it cancels the original.</summary>
    private static ClaimPayment Reverse(ClaimPayment original)
    {
        var rev = new ClaimPayment
        {
            PatientControlNumber = original.PatientControlNumber, StatusCode = "22",
            ChargeAmount = -original.ChargeAmount, PaidAmount = -original.PaidAmount,
            PatientResponsibility = -original.PatientResponsibility,
            PayerClaimControlNumber = original.PayerClaimControlNumber,
            PatientMemberId = original.PatientMemberId, StatementFromDate = original.StatementFromDate,
        };
        foreach (var l in original.ServiceLines)
        {
            var rl = new ServiceLinePayment
            {
                ProcedureCode = l.ProcedureCode, ChargeAmount = -l.ChargeAmount, PaidAmount = -l.PaidAmount,
                Units = l.Units, ServiceDate = l.ServiceDate,
            };
            rl.Adjustments.AddRange(l.Adjustments.Select(a => a with { Amount = -a.Amount }));
            rev.ServiceLines.Add(rl);
        }
        return rev;
    }

    /// <summary>Corrected claim: payer moves part of the CO-45 write-off on the first line to payment.</summary>
    private static ClaimPayment Readjudicate(ClaimPayment original, decimal extraPaid)
    {
        var fixedClaim = new ClaimPayment
        {
            PatientControlNumber = original.PatientControlNumber, StatusCode = "1",
            ChargeAmount = original.ChargeAmount, PaidAmount = 0,
            PayerClaimControlNumber = original.PayerClaimControlNumber + "R",
            PatientMemberId = original.PatientMemberId, StatementFromDate = original.StatementFromDate,
        };
        for (int i = 0; i < original.ServiceLines.Count; i++)
        {
            var l = original.ServiceLines[i];
            decimal bump = i == 0 ? extraPaid : 0m;
            var nl = new ServiceLinePayment
            {
                ProcedureCode = l.ProcedureCode, ChargeAmount = l.ChargeAmount, PaidAmount = l.PaidAmount + bump,
                Units = l.Units, ServiceDate = l.ServiceDate,
            };
            nl.Adjustments.AddRange(l.Adjustments.Select(a =>
                a.GroupCode == "CO" && a.ReasonCode == "45" ? a with { Amount = a.Amount - bump } : a));
            fixedClaim.ServiceLines.Add(nl);
        }
        return WithTotals(fixedClaim);
    }

    // ---- planted defects ------------------------------------------------------------------------

    private static void Corrupt_LineAdjustmentShort(ClaimPayment claim, decimal shortBy)
    {
        var adjustments = claim.ServiceLines[0].Adjustments;
        int i = adjustments.FindIndex(a => a.GroupCode == "CO");
        adjustments[i] = adjustments[i] with { Amount = adjustments[i].Amount - shortBy };
    }

    private static void Corrupt_PatientRespHeader(Remittance remit, string pcn, decimal extra)
    {
        int i = remit.Claims.FindIndex(c => c.PatientControlNumber == pcn);
        var c = remit.Claims[i];
        var bad = new ClaimPayment
        {
            PatientControlNumber = c.PatientControlNumber, StatusCode = c.StatusCode,
            ChargeAmount = c.ChargeAmount, PaidAmount = c.PaidAmount,
            PatientResponsibility = c.PatientResponsibility + extra,
            PayerClaimControlNumber = c.PayerClaimControlNumber, PatientMemberId = c.PatientMemberId,
            StatementFromDate = c.StatementFromDate,
        };
        bad.ServiceLines.AddRange(c.ServiceLines);
        remit.Claims[i] = bad;
    }

    private static void DropLine(ClaimPayment claim, string cpt, Remittance remit)
    {
        claim.ServiceLines.RemoveAll(l => l.ProcedureCode == cpt);
        int i = remit.Claims.IndexOf(claim);
        remit.Claims[i] = WithTotals(claim);
    }
}
