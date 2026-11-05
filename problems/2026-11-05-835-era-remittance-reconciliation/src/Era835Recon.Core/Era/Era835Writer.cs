using System.Globalization;
using System.Text;

namespace Era835Recon.Core.Era;

/// <summary>
/// Serializes a <see cref="Remittance"/> to X12 835 text. Used to build synthetic test files
/// and to prove the parser round-trips. Delimiters: * element, : component, ~ segment.
/// </summary>
public static class Era835Writer
{
    public static string Write(Remittance remit, int interchangeControlNumber, DateTime createdAt)
    {
        var segments = new List<string>();
        void Seg(params string[] parts) => segments.Add(string.Join('*', parts).TrimEnd('*'));

        string payDate = D(remit.PaymentDate ?? DateOnly.FromDateTime(createdAt));
        string ctl = interchangeControlNumber.ToString("D9", CultureInfo.InvariantCulture);

        // Transaction set (ST..SE). Envelope segments are added afterwards.
        Seg("ST", "835", "0001", "005010X221A1");
        Seg("BPR", "I", M(remit.TotalPaymentAmount), "C", remit.PaymentMethod, "CCP", "01", "999999999", "DA",
            "123456", "1512345678", "", "01", "999988880", "DA", "98765", payDate);
        Seg("TRN", "1", remit.TraceNumber, "1512345678");
        Seg("DTM", "405", payDate);
        Seg("N1", "PR", remit.PayerName, "XV", remit.PayerId);
        Seg("N3", "100 SYNTHETIC PLAZA");
        Seg("N4", "SAMPLETOWN", "PA", "17000");
        Seg("N1", "PE", remit.PayeeName, "XX", remit.PayeeNpi);
        Seg("LX", "1");

        foreach (var claim in remit.Claims)
        {
            Seg("CLP", claim.PatientControlNumber, claim.StatusCode, M(claim.ChargeAmount), M(claim.PaidAmount),
                M(claim.PatientResponsibility), "12", claim.PayerClaimControlNumber, "11", "1");
            WriteCas(claim.Adjustments, Seg);
            Seg("NM1", "QC", "1", "SYNTHETIC", "PATIENT", "", "", "", "MI", claim.PatientMemberId);
            if (claim.StatementFromDate is { } from) Seg("DTM", "232", D(from));

            foreach (var line in claim.ServiceLines)
            {
                Seg("SVC", "HC:" + line.ProcedureCode, M(line.ChargeAmount), M(line.PaidAmount), "", M(line.Units));
                if (line.ServiceDate is { } dos) Seg("DTM", "472", D(dos));
                WriteCas(line.Adjustments, Seg);
            }
        }

        if (remit.ProviderAdjustments.Count > 0)
        {
            var plb = new List<string> { "PLB", remit.PayeeNpi, $"{payDate[..4]}1231" };
            foreach (var p in remit.ProviderAdjustments)
            {
                plb.Add(string.IsNullOrEmpty(p.Reference) ? p.ReasonCode : $"{p.ReasonCode}:{p.Reference}");
                plb.Add(M(p.Amount));
            }
            Seg(plb.ToArray());
        }
        Seg("SE", (segments.Count + 1).ToString(CultureInfo.InvariantCulture), "0001");

        // Interchange envelope. ISA is fixed width; ISA16 (component separator) sits at position 104.
        string isa = string.Join('*', "ISA", "00", new string(' ', 10), "00", new string(' ', 10),
            "ZZ", remit.PayerId.PadRight(15), "ZZ", remit.PayeeNpi.PadRight(15),
            createdAt.ToString("yyMMdd", CultureInfo.InvariantCulture),
            createdAt.ToString("HHmm", CultureInfo.InvariantCulture),
            "^", "00501", ctl, "0", "P", ":");
        var sb = new StringBuilder();
        sb.Append(isa).Append("~\n");
        sb.Append($"GS*HP*{remit.PayerId}*{remit.PayeeNpi}*{createdAt:yyyyMMdd}*{createdAt:HHmm}*{interchangeControlNumber}*X*005010X221A1~\n");
        foreach (var s in segments) sb.Append(s).Append("~\n");
        sb.Append($"GE*1*{interchangeControlNumber}~\n");
        sb.Append($"IEA*1*{ctl}~\n");
        return sb.ToString();
    }

    /// <summary>One CAS segment per group code, up to six reason/amount pairs each.</summary>
    private static void WriteCas(IEnumerable<Adjustment> adjustments, Action<string[]> seg)
    {
        foreach (var group in adjustments.GroupBy(a => a.GroupCode))
            foreach (var chunk in group.Chunk(6))
            {
                var parts = new List<string> { "CAS", group.Key };
                foreach (var a in chunk) { parts.Add(a.ReasonCode); parts.Add(M(a.Amount)); parts.Add(""); }
                seg(parts.ToArray());
            }
    }

    // X12 numeric (R) elements: no thousands separators, no trailing zeros.
    private static string M(decimal value) => value.ToString("0.##", CultureInfo.InvariantCulture);
    private static string D(DateOnly date) => date.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
}
