namespace Era835Recon.Tests;

/// <summary>Hand-written 835 fragments for focused tests (synthetic values only).</summary>
internal static class Sample835
{
    private const string Isa =
        "ISA*00*          *00*          *ZZ*99001          *ZZ*1234567893     *261105*0600*^*00501*000000001*0*P*:~";

    /// <summary>Wraps body segments (one per line, without terminators) in ST/SE plus an envelope.</summary>
    public static string Wrap(params string[] body)
    {
        var lines = new List<string> { Isa, "GS*HP*99001*1234567893*20261105*0600*1*X*005010X221A1~", "ST*835*0001*005010X221A1~" };
        lines.AddRange(body.Select(s => s + "~"));
        lines.Add($"SE*{body.Length + 2}*0001~");
        lines.Add("GE*1*1~");
        lines.Add("IEA*1*000000001~");
        return string.Join("\r\n", lines);
    }

    /// <summary>
    /// One balanced claim: charge 200 = paid 120 + CO 40 + PR 40.
    /// Line 1 (99213 135): paid 80, CO-45 30, PR-3 25.
    /// Line 2 (80053 65):  paid 40, CO-45 10, PR-1 10, PR-2 5.
    /// </summary>
    public static string BalancedClaim(string bpr02 = "120", string pcn = "PCN1") => Wrap(
        $"BPR*I*{bpr02}*C*ACH*CCP*01*999999999*DA*123456*1512345678**01*999988880*DA*98765*20261001",
        "TRN*1*EFT0001*1512345678",
        "N1*PR*SYNTHETIC HEALTH PLAN*XV*99001",
        "N1*PE*SYNTHETIC FAMILY CLINIC*XX*1234567893",
        "LX*1",
        $"CLP*{pcn}*1*200*120*40*12*ICN0001*11*1",
        "NM1*QC*1*SYNTHETIC*PATIENT****MI*SYN000001",
        "DTM*232*20260920",
        "SVC*HC:99213:25*135*80**1",
        "DTM*472*20260920",
        "CAS*CO*45*30",
        "CAS*PR*3*25",
        "SVC*HC:80053*65*40**1",
        "DTM*472*20260920",
        "CAS*CO*45*10",
        "CAS*PR*1*10**2*5"); // two reason/amount triplets in one CAS: deductible 10, coinsurance 5
}
