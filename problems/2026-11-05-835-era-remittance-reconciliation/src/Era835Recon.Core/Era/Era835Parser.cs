using System.Globalization;
using Era835Recon.Core.X12;

namespace Era835Recon.Core.Era;

/// <summary>
/// Parses X12 005010X221A1 (835 Health Care Claim Payment/Advice) into an object model.
///
/// The 835 is a flat list of segments, and the loop a segment belongs to is implied by
/// what came before it. For example a CAS after CLP is a claim-level adjustment,
/// but a CAS after SVC belongs to that service line. The parser therefore walks the
/// segments once and keeps "where am I" state: current remittance, claim and service line.
/// </summary>
public static class Era835Parser
{
    public static IReadOnlyList<Remittance> ParseFile(string path) =>
        Parse(File.ReadAllText(path), Path.GetFileName(path));

    public static IReadOnlyList<Remittance> Parse(string rawInterchange, string sourceName)
    {
        var remittances = new List<Remittance>();
        Remittance? remit = null;
        ClaimPayment? claim = null;
        ServiceLinePayment? line = null;
        string currentN1 = "";

        foreach (var seg in X12Reader.Parse(rawInterchange))
        {
            switch (seg.Id)
            {
                case "ST":
                    if (seg.Element(1) != "835")
                        throw new FormatException($"{sourceName}: expected ST*835, found ST*{seg.Element(1)}.");
                    remit = new Remittance { SourceFile = sourceName };
                    remittances.Add(remit);
                    claim = null; line = null; currentN1 = "";
                    break;

                case "BPR": // financial information
                    Require(remit, seg).TotalPaymentAmount = Money(seg.Element(2));
                    remit!.PaymentMethod = seg.Element(4);
                    remit.PaymentDate = Date(seg.Element(16));
                    break;

                case "TRN": // reassociation trace: links the 835 to the EFT/check
                    Require(remit, seg).TraceNumber = seg.Element(2);
                    break;

                case "N1":
                    currentN1 = seg.Element(1);
                    if (currentN1 == "PR")
                    {
                        Require(remit, seg).PayerName = seg.Element(2);
                        if (seg.Element(3) == "XV" || seg.Element(3) == "PI") remit!.PayerId = seg.Element(4);
                    }
                    else if (currentN1 == "PE")
                    {
                        Require(remit, seg).PayeeName = seg.Element(2);
                        if (seg.Element(3) == "XX") remit!.PayeeNpi = seg.Element(4);
                    }
                    break;

                case "REF": // REF*2U = payer identification, only meaningful in the payer N1 loop
                    if (claim is null && currentN1 == "PR" && seg.Element(1) == "2U")
                        Require(remit, seg).PayerId = seg.Element(2);
                    break;

                case "CLP": // start of a claim payment loop
                    claim = new ClaimPayment
                    {
                        PatientControlNumber = seg.Element(1),
                        StatusCode = seg.Element(2),
                        ChargeAmount = Money(seg.Element(3)),
                        PaidAmount = Money(seg.Element(4)),
                        PatientResponsibility = Money(seg.Element(5)),
                        PayerClaimControlNumber = seg.Element(7),
                    };
                    var owner = Require(remit, seg);
                    claim.TraceNumber = owner.TraceNumber;
                    claim.PayerId = owner.PayerId;
                    owner.Claims.Add(claim);
                    line = null;
                    break;

                case "NM1":
                    if (claim is not null && seg.Element(1) == "QC") claim.PatientMemberId = seg.Element(9);
                    break;

                case "SVC": // start of a service line loop inside the current claim
                    var procedure = seg.Components(1);
                    line = new ServiceLinePayment
                    {
                        ProcedureCode = procedure.Length > 1 ? procedure[1] : procedure[0],
                        ChargeAmount = Money(seg.Element(2)),
                        PaidAmount = Money(seg.Element(3)),
                        Units = string.IsNullOrEmpty(seg.Element(5)) ? 1 : Money(seg.Element(5)),
                    };
                    RequireClaim(claim, seg).ServiceLines.Add(line);
                    break;

                case "CAS":
                    var adjustments = ReadCas(seg);
                    if (line is not null) line.Adjustments.AddRange(adjustments);
                    else RequireClaim(claim, seg).Adjustments.AddRange(adjustments);
                    break;

                case "DTM":
                    if (seg.Element(1) == "232" && claim is not null) claim.StatementFromDate = Date(seg.Element(2));
                    if (seg.Element(1) == "472" && line is not null) line.ServiceDate = Date(seg.Element(2));
                    break;

                case "PLB": // provider-level adjustments come after all claims, in reason/amount pairs
                    claim = null; line = null;
                    for (int i = 3; i + 1 <= seg.Elements.Count; i += 2)
                    {
                        if (string.IsNullOrEmpty(seg.Element(i))) continue;
                        var reason = seg.Components(i);
                        Require(remit, seg).ProviderAdjustments.Add(new ProviderAdjustment(
                            reason[0], reason.Length > 1 ? reason[1] : "", Money(seg.Element(i + 1))));
                    }
                    break;

                case "SE":
                    remit = null; claim = null; line = null;
                    break;
            }
        }
        return remittances;
    }

    /// <summary>CAS*group*reason1*amt1*qty1*reason2*amt2*qty2... up to six reason/amount triplets.</summary>
    private static IEnumerable<Adjustment> ReadCas(X12Segment seg)
    {
        var group = seg.Element(1);
        for (int i = 2; i <= 17; i += 3)
        {
            var reason = seg.Element(i);
            if (string.IsNullOrEmpty(reason)) yield break;
            yield return new Adjustment(group, reason, Money(seg.Element(i + 1)));
        }
    }

    private static decimal Money(string value) =>
        string.IsNullOrWhiteSpace(value) ? 0m : decimal.Parse(value, NumberStyles.Number, CultureInfo.InvariantCulture);

    private static DateOnly? Date(string value) =>
        DateOnly.TryParseExact(value, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;

    private static Remittance Require(Remittance? remit, X12Segment seg) =>
        remit ?? throw new FormatException($"{seg.Id} segment found outside an ST*835 transaction.");

    private static ClaimPayment RequireClaim(ClaimPayment? claim, X12Segment seg) =>
        claim ?? throw new FormatException($"{seg.Id} segment found before any CLP claim loop.");
}
