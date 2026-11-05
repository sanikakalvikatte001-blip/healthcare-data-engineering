using System.Globalization;
using Era835Recon.Core.Era;
using Era835Recon.Core.Ledger;
using Era835Recon.Core.Output;
using Era835Recon.Core.Reconciliation;
using Era835Recon.Core.Synthetic;

// era835-recon: a small CLI around the Era835Recon.Core library.
//
//   generate  [--data data]                       write the synthetic ledger + 835 files
//   reconcile [--data data] [--out output]         parse 835s, balance them, match to the ledger
//             [--as-of 2026-11-05] [--follow-up-days 30]

var command = args.FirstOrDefault() ?? "help";
string Option(string name, string fallback)
{
    int i = Array.IndexOf(args, "--" + name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : fallback;
}

string dataDir = Option("data", "data");
string eraDir = Path.Combine(dataDir, "era");
string ledgerPath = Path.Combine(dataDir, "claims_837_ledger.csv");

switch (command)
{
    case "generate":
    {
        var output = new SyntheticDataGenerator(seed: 835).Generate();
        Directory.CreateDirectory(eraDir);
        ClaimLedger.Save(ledgerPath, output.Ledger);
        foreach (var (name, content) in output.EraFiles) File.WriteAllText(Path.Combine(eraDir, name), content);
        Console.WriteLine($"Wrote {output.Ledger.Count} ledger claims to {ledgerPath}");
        Console.WriteLine($"Wrote {output.EraFiles.Count} 835 files to {eraDir}");
        return 0;
    }

    case "reconcile":
    {
        var asOf = DateOnly.ParseExact(Option("as-of", SyntheticDataGenerator.AsOfDate.ToString("yyyy-MM-dd")),
            "yyyy-MM-dd", CultureInfo.InvariantCulture);
        int followUp = int.Parse(Option("follow-up-days", "30"), CultureInfo.InvariantCulture);
        string outDir = Option("out", "output");

        var ledger = ClaimLedger.Load(ledgerPath);
        // Files are loaded in name order, which for these feeds is received order.
        var remits = Directory.GetFiles(eraDir, "*.835").Order(StringComparer.Ordinal)
            .SelectMany(Era835Parser.ParseFile).ToList();

        var result = new RemitReconciler(asOf, followUp).Reconcile(ledger, remits);
        CsvExport.WriteAll(outDir, result);

        var summary = Summarize(ledger, remits, result, asOf);
        File.WriteAllText(Path.Combine(outDir, "summary.txt"), summary);
        Console.Write(summary);

        // Non-zero exit when any error-level exception exists, so a scheduler can alert on it.
        return result.Exceptions.Any(e => e.Severity == Severity.Error) ? 2 : 0;
    }

    default:
        Console.WriteLine("usage: era835-recon generate|reconcile [--data dir] [--out dir] [--as-of yyyy-MM-dd] [--follow-up-days n]");
        return command == "help" ? 0 : 1;
}

static string Summarize(IReadOnlyList<SubmittedClaim> ledger, IReadOnlyList<Remittance> parsed,
    ReconciliationResult result, DateOnly asOf)
{
    var inv = CultureInfo.InvariantCulture;
    var sw = new StringWriter(inv);
    sw.WriteLine($"835 ERA reconciliation as of {asOf:yyyy-MM-dd}");
    sw.WriteLine(new string('=', 60));
    sw.WriteLine($"Ledger claims (837 submitted) : {ledger.Count}");
    sw.WriteLine($"835 transactions parsed       : {parsed.Count}");
    sw.WriteLine($"835 transactions accepted     : {result.AcceptedRemittances.Count} (duplicates skipped: {parsed.Count - result.AcceptedRemittances.Count})");
    sw.WriteLine($"Claim payment loops (CLP)     : {result.AcceptedRemittances.Sum(r => r.Claims.Count)}");
    sw.WriteLine();

    sw.WriteLine("Payments by check/EFT");
    foreach (var r in result.AcceptedRemittances)
        sw.WriteLine(string.Format(inv, "  {0,-15} {1,-5} {2,4} claims  BPR02 {3,10:N2}  PLB {4,8:N2}",
            r.TraceNumber, r.PayerId, r.Claims.Count, r.TotalPaymentAmount, r.ProviderAdjustments.Sum(p => p.Amount)));
    sw.WriteLine();

    sw.WriteLine("Claim status                 claims      billed    net paid   open ins bal");
    foreach (var g in result.Rows.GroupBy(r => r.Status).OrderBy(g => g.Key))
        sw.WriteLine(string.Format(inv, "  {0,-24} {1,6} {2,11:N2} {3,11:N2} {4,14:N2}",
            CsvExport.ToSnake(g.Key), g.Count(), g.Sum(r => r.BilledAmount), g.Sum(r => r.NetPaid), g.Sum(r => r.OpenInsuranceBalance)));
    sw.WriteLine(string.Format(inv, "  {0,-24} {1,6} {2,11:N2} {3,11:N2} {4,14:N2}", "TOTAL", result.Rows.Count,
        result.Rows.Sum(r => r.BilledAmount), result.Rows.Sum(r => r.NetPaid), result.Rows.Sum(r => r.OpenInsuranceBalance)));
    sw.WriteLine();

    var ledgerRows = result.Rows.Where(r => r.Status != ReconStatus.UnmatchedRemit).ToList();
    sw.WriteLine(string.Format(inv, "Adjustment mix (ledger claims): contractual {0:N2} | patient resp {1:N2} | other {2:N2}",
        ledgerRows.Sum(r => r.NetContractualAdjustment), ledgerRows.Sum(r => r.NetPatientResponsibility), ledgerRows.Sum(r => r.NetOtherAdjustment)));
    sw.WriteLine();

    sw.WriteLine("Exceptions");
    foreach (var e in result.Exceptions)
        sw.WriteLine($"  [{e.Severity,-7}] {e.Rule,-20} {e.PatientControlNumber,-10} {e.Message}");
    return sw.ToString();
}
