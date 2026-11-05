using Era835Recon.Core.Era;
using Era835Recon.Core.Synthetic;
using Era835Recon.Core.X12;

namespace Era835Recon.Tests;

public class X12ReaderTests
{
    [Fact]
    public void Reads_delimiters_from_the_isa_header_instead_of_assuming_them()
    {
        // Same interchange with | as element separator, > as component separator, newline as terminator.
        var raw = Sample835.BalancedClaim().Replace("~\r\n", "\n").Replace('*', '|').Replace(':', '>');

        var segments = X12Reader.Parse(raw);
        var svc = segments.First(s => s.Id == "SVC");

        Assert.Equal("ISA", segments[0].Id);
        Assert.Equal("99213", svc.Components(1)[1]);
        Assert.Equal("135", svc.Element(2));
    }

    [Fact]
    public void Rejects_input_that_is_not_an_interchange() =>
        Assert.Throws<FormatException>(() => X12Reader.Parse("CLP*PCN1*1*100*80~"));

    [Fact]
    public void Missing_elements_read_as_empty_strings()
    {
        var clp = X12Reader.Parse(Sample835.BalancedClaim()).First(s => s.Id == "CLP");
        Assert.Equal("", clp.Element(14));
    }
}

public class Era835ParserTests
{
    private static ClaimPayment ParseSingleClaim(string raw) =>
        Assert.Single(Assert.Single(Era835Parser.Parse(raw, "test.835")).Claims);

    [Fact]
    public void Parses_header_payer_and_payee()
    {
        var remit = Assert.Single(Era835Parser.Parse(Sample835.BalancedClaim(), "test.835"));
        Assert.Equal(120m, remit.TotalPaymentAmount);
        Assert.Equal("EFT0001", remit.TraceNumber);
        Assert.Equal("99001", remit.PayerId);
        Assert.Equal("1234567893", remit.PayeeNpi);
        Assert.Equal(new DateOnly(2026, 10, 1), remit.PaymentDate!.Value);
    }

    [Fact]
    public void Cas_after_svc_belongs_to_the_service_line_not_the_claim()
    {
        var claim = ParseSingleClaim(Sample835.BalancedClaim());
        Assert.Empty(claim.Adjustments);
        Assert.Equal(2, claim.ServiceLines[0].Adjustments.Count);
        Assert.Equal("99213", claim.ServiceLines[0].ProcedureCode);  // modifier :25 is not part of the code
    }

    [Fact]
    public void Cas_with_several_triplets_yields_one_adjustment_per_reason()
    {
        var line2 = ParseSingleClaim(Sample835.BalancedClaim()).ServiceLines[1];
        var pr = line2.Adjustments.Where(a => a.GroupCode == "PR").ToList();
        Assert.Equal(2, pr.Count);
        Assert.Equal(new Adjustment("PR", "1", 10m), pr[0]);
        Assert.Equal(new Adjustment("PR", "2", 5m), pr[1]);
    }

    [Fact]
    public void Claim_level_cas_before_any_svc_stays_on_the_claim()
    {
        var raw = Sample835.Wrap("BPR*I*0*C*NON", "TRN*1*T1*1", "N1*PR*P*XV*99001",
            "CLP*PCN9*4*100*0*0*12*ICN9", "CAS*CO*16*100");
        var claim = ParseSingleClaim(raw);
        Assert.True(claim.IsDenied);
        Assert.Equal(new Adjustment("CO", "16", 100m), Assert.Single(claim.Adjustments));
    }

    [Fact]
    public void Reads_plb_reason_reference_and_amount_pairs()
    {
        var raw = Sample835.Wrap("BPR*I*63.42*C*ACH", "TRN*1*T1*1", "N1*PR*P*XV*99001",
            "CLP*PCN1*1*100*100*0*12*ICN1",
            "PLB*1234567893*20261231*L6:PCN1*-3.42*WO:OLD77*40");
        var remit = Assert.Single(Era835Parser.Parse(raw, "t"));
        Assert.Equal(2, remit.ProviderAdjustments.Count);
        Assert.Equal(new ProviderAdjustment("L6", "PCN1", -3.42m), remit.ProviderAdjustments[0]);
        Assert.Equal(new ProviderAdjustment("WO", "OLD77", 40m), remit.ProviderAdjustments[1]);
    }

    [Fact]
    public void Reversal_keeps_negative_amounts()
    {
        var raw = Sample835.Wrap("BPR*I*0*C*NON", "TRN*1*T1*1", "N1*PR*P*XV*99001",
            "CLP*PCN1*22*-200*-120*-40*12*ICN1", "SVC*HC:99213*-200*-120**1", "CAS*CO*45*-40", "CAS*PR*3*-40");
        var claim = ParseSingleClaim(raw);
        Assert.True(claim.IsReversal);
        Assert.Equal(-120m, claim.PaidAmount);
        Assert.Equal(-80m, claim.AllAdjustments.Sum(a => a.Amount));
    }

    [Fact]
    public void Cas_before_any_claim_is_a_format_error() =>
        Assert.Throws<FormatException>(() => Era835Parser.Parse(
            Sample835.Wrap("BPR*I*0*C*NON", "CAS*CO*45*10"), "bad.835"));

    [Fact]
    public void Writer_output_round_trips_through_the_parser()
    {
        var generated = new SyntheticDataGenerator(seed: 835).Generate();
        var (name, content) = generated.EraFiles[0];
        var remit = Assert.Single(Era835Parser.Parse(content, name));

        Assert.Equal(15, remit.Claims.Count);
        Assert.Equal("EFT0091500001", remit.TraceNumber);
        Assert.Equal(remit.Claims.Sum(c => c.PaidAmount) - remit.ProviderAdjustments.Sum(p => p.Amount),
            remit.TotalPaymentAmount);
    }
}
