using System.Globalization;
using Era835Recon.Core.Era;
using Era835Recon.Core.Reconciliation;

namespace Era835Recon.Core.Output;

/// <summary>
/// Writes the parsed and reconciled results as flat CSV files, shaped like the warehouse
/// tables they would load into (remit claim, remit adjustment, exception, reconciliation fact).
/// </summary>
public static class CsvExport
{
    public static void WriteAll(string outputDir, ReconciliationResult result)
    {
        Directory.CreateDirectory(outputDir);
        var remits = result.AcceptedRemittances;

        Write(Path.Combine(outputDir, "remit_claims.csv"),
            "source_file,trace_number,payer_id,patient_control_number,claim_status_code,charge_amount,paid_amount,patient_responsibility,payer_claim_control_number,member_id,statement_from_date,service_line_count",
            remits.SelectMany(r => r.Claims.Select(c => new object?[]
            {
                r.SourceFile, r.TraceNumber, r.PayerId, c.PatientControlNumber, c.StatusCode, c.ChargeAmount,
                c.PaidAmount, c.PatientResponsibility, c.PayerClaimControlNumber, c.PatientMemberId,
                c.StatementFromDate, c.ServiceLines.Count,
            })));

        Write(Path.Combine(outputDir, "remit_adjustments.csv"),
            "source_file,trace_number,patient_control_number,adjustment_level,procedure_code,group_code,reason_code,amount",
            remits.SelectMany(r => r.Claims.SelectMany(c =>
                c.Adjustments.Select(a => new object?[] { r.SourceFile, r.TraceNumber, c.PatientControlNumber, "CLAIM", "", a.GroupCode, a.ReasonCode, a.Amount })
                .Concat(c.ServiceLines.SelectMany(l => l.Adjustments.Select(a =>
                    new object?[] { r.SourceFile, r.TraceNumber, c.PatientControlNumber, "LINE", l.ProcedureCode, a.GroupCode, a.ReasonCode, a.Amount }))))));

        Write(Path.Combine(outputDir, "exceptions.csv"),
            "severity,rule,source_file,trace_number,patient_control_number,expected,actual,difference,message",
            result.Exceptions.Select(e => new object?[]
            {
                e.Severity, e.Rule, e.SourceFile, e.TraceNumber, e.PatientControlNumber, e.Expected, e.Actual, e.Difference, e.Message,
            }));

        Write(Path.Combine(outputDir, "reconciliation.csv"),
            "claim_id,payer_id,status,billed_amount,remit_count,net_paid,net_contractual_adj,net_patient_resp,net_other_adj,open_insurance_balance,days_since_submission,detail",
            result.Rows.OrderBy(r => r.ClaimId).Select(r => new object?[]
            {
                r.ClaimId, r.PayerId, ToSnake(r.Status), r.BilledAmount, r.RemitCount, r.NetPaid, r.NetContractualAdjustment,
                r.NetPatientResponsibility, r.NetOtherAdjustment, r.OpenInsuranceBalance, r.DaysSinceSubmission, r.Detail,
            }));
    }

    /// <summary>ReversedNotRepaid -> REVERSED_NOT_REPAID (warehouse-friendly status codes).</summary>
    public static string ToSnake(ReconStatus status) =>
        string.Concat(status.ToString().Select((ch, i) => i > 0 && char.IsUpper(ch) ? "_" + ch : ch.ToString())).ToUpperInvariant();

    private static void Write(string path, string header, IEnumerable<object?[]> rows)
    {
        using var w = new StreamWriter(path);
        w.WriteLine(header);
        foreach (var row in rows) w.WriteLine(string.Join(',', row.Select(Format)));
    }

    private static string Format(object? value) => value switch
    {
        null => "",
        decimal d => d.ToString("0.00", CultureInfo.InvariantCulture),
        DateOnly d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => Quote(value.ToString() ?? ""),
    };

    private static string Quote(string s) =>
        s.IndexOfAny(new[] { ',', '"', '\n' }) >= 0 ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
}
