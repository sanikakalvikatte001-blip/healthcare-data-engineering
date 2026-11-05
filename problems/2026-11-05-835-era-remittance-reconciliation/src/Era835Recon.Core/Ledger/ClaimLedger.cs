using System.Globalization;

namespace Era835Recon.Core.Ledger;

/// <summary>
/// A claim we sent on an 837 and are waiting to be paid for.
/// ClaimId is CLM01, which the payer echoes back in the 835 as CLP01.
/// </summary>
public sealed record SubmittedClaim(
    string ClaimId,
    string PayerId,
    string MemberId,
    DateOnly ServiceFromDate,
    DateOnly SubmittedDate,
    decimal BilledAmount,
    int LineCount);

/// <summary>Reads and writes the submitted-claims ledger (a CSV extract of the billing system's 837 log).</summary>
public static class ClaimLedger
{
    public const string Header = "claim_id,payer_id,member_id,service_from_date,submitted_date,billed_amount,line_count";

    public static IReadOnlyList<SubmittedClaim> Load(string path)
    {
        var lines = File.ReadAllLines(path);
        if (lines.Length == 0 || lines[0].Trim() != Header)
            throw new FormatException($"{path}: unexpected header. Expected '{Header}'.");

        return lines.Skip(1)
            .Where(l => !string.IsNullOrWhiteSpace(l))
            .Select((l, i) =>
            {
                var f = l.Split(',');
                if (f.Length != 7) throw new FormatException($"{path}: line {i + 2} has {f.Length} fields, expected 7.");
                return new SubmittedClaim(
                    f[0], f[1], f[2],
                    DateOnly.ParseExact(f[3], "yyyy-MM-dd", CultureInfo.InvariantCulture),
                    DateOnly.ParseExact(f[4], "yyyy-MM-dd", CultureInfo.InvariantCulture),
                    decimal.Parse(f[5], CultureInfo.InvariantCulture),
                    int.Parse(f[6], CultureInfo.InvariantCulture));
            })
            .ToList();
    }

    public static void Save(string path, IEnumerable<SubmittedClaim> claims)
    {
        var rows = claims.Select(c => string.Join(',',
            c.ClaimId, c.PayerId, c.MemberId,
            c.ServiceFromDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            c.SubmittedDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            c.BilledAmount.ToString("0.00", CultureInfo.InvariantCulture),
            c.LineCount.ToString(CultureInfo.InvariantCulture)));
        File.WriteAllLines(path, new[] { Header }.Concat(rows));
    }
}
