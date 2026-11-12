using System.Text;
using System.Xml.Linq;
using CcdaIngest.Hashing;
using CcdaIngest.Model;
using CcdaIngest.Parsing;
using CcdaIngest.Synthetic;
using Xunit;

namespace CcdaIngest.Tests;

public class FingerprintTests
{
    private static readonly XDocument Ava = CcdaBuilder.Build(SyntheticFeed.AvaCcd);

    [Fact]
    public void Reserialized_document_has_different_bytes_but_same_canonical_hash()
    {
        var standard = CcdaBuilder.Serialize(Ava);
        var other = CcdaBuilder.SerializeAsOtherSystem(Ava);

        Assert.NotEqual(DocumentFingerprint.FileSha256(standard), DocumentFingerprint.FileSha256(other));
        Assert.Equal(
            DocumentFingerprint.CanonicalSha256(CcdaParser.LoadXml(standard)),
            DocumentFingerprint.CanonicalSha256(CcdaParser.LoadXml(other)));
    }

    [Fact]
    public void A_single_changed_lab_value_changes_the_canonical_hash()
    {
        var changed = CcdaBuilder.Build(SyntheticFeed.AvaCcd with
        {
            Results = [SyntheticFeed.AvaCcd.Results[0] with { Value = "7.5" }, SyntheticFeed.AvaCcd.Results[1]],
        });
        Assert.NotEqual(DocumentFingerprint.CanonicalSha256(Ava), DocumentFingerprint.CanonicalSha256(changed));
    }

    [Fact]
    public void Canonical_form_ignores_comments_whitespace_attribute_order_and_prefixes()
    {
        const string a = """<r xmlns="urn:hl7-org:v3"><code code="1" codeSystem="2.16"/><t>  some   text </t></r>""";
        const string b = """
            <?xml version="1.0"?>
            <!-- leading comment -->
            <h:r xmlns:h="urn:hl7-org:v3">
                <h:code codeSystem="2.16"   code="1" />
                <!-- inner comment -->
                <h:t>some text</h:t>
            </h:r>
            """;
        Assert.Equal(DocumentFingerprint.CanonicalText(XDocument.Parse(a)), DocumentFingerprint.CanonicalText(XDocument.Parse(b)));
    }

    [Fact]
    public void Namespace_is_part_of_identity()
    {
        var hl7 = XDocument.Parse("""<r xmlns="urn:hl7-org:v3"><x/></r>""");
        var other = XDocument.Parse("""<r xmlns="urn:other"><x/></r>""");
        Assert.NotEqual(DocumentFingerprint.CanonicalSha256(hl7), DocumentFingerprint.CanonicalSha256(other));
    }
}

public class ParserTests
{
    [Fact]
    public void Parses_header_ids_version_patient_and_time()
    {
        var doc = CcdaParser.Parse(CcdaBuilder.Build(SyntheticFeed.AvaCcd));

        Assert.Equal($"{CcdaBuilder.DocumentRoot}^CCD-A-0001", doc.DocumentId);
        Assert.Equal($"{CcdaBuilder.DocumentRoot}^SET-A", doc.SetId);
        Assert.Equal(1, doc.Version);
        Assert.Equal(null, doc.ReplacesDocumentId);
        Assert.Equal(new DateTimeOffset(2026, 11, 3, 14, 15, 0, TimeSpan.Zero), doc.EffectiveTime.ToUniversalTime());
        Assert.Equal(new Patient($"{CcdaBuilder.MrnRoot}^100001", "Ava", "Thornton", "1958-03-14", "F"), doc.Patient);
    }

    [Theory]
    [InlineData(EntryType.Problem, 2)]
    [InlineData(EntryType.Medication, 2)]
    [InlineData(EntryType.Allergy, 1)]
    [InlineData(EntryType.Result, 2)]
    public void Extracts_each_section_by_loinc_code(EntryType type, int expected)
    {
        var doc = CcdaParser.Parse(CcdaBuilder.Build(SyntheticFeed.AvaCcd));
        Assert.Equal(expected, doc.Entries.Count(e => e.Type == type));
    }

    [Fact]
    public void Flattens_coded_entries_with_dates_values_and_units()
    {
        var doc = CcdaParser.Parse(CcdaBuilder.Build(SyntheticFeed.AvaEncounter));

        var lisinopril = Assert.Single(doc.Entries.Where(e => e.Code == "314076"));
        Assert.Equal(("completed", "2023-06-01", "2026-11-11", "2.16.840.1.113883.6.88"),
            (lisinopril.Status, lisinopril.EffectiveStart, lisinopril.EffectiveEnd, lisinopril.CodeSystem));

        var penicillin = Assert.Single(doc.Entries.Where(e => e.Type == EntryType.Allergy));
        Assert.Equal(("7980", "Penicillin G"), (penicillin.Code, penicillin.Display));

        var a1c = doc.Entries.Single(e => e.Code == "4548-4" && e.EffectiveStart == "2026-11-10");
        Assert.Equal(("6.9", "%"), (a1c.Value, a1c.Unit));
    }

    [Fact]
    public void NullFlavor_code_becomes_an_entry_exception_not_a_row()
    {
        var doc = CcdaParser.Parse(CcdaBuilder.Build(SyntheticFeed.MarcusCcdV1));

        Assert.Equal(2, doc.Entries.Count(e => e.Type == EntryType.Problem));
        var ex = Assert.Single(doc.Exceptions);
        Assert.Equal((EntryType.Problem, "Problem entry code is nullFlavor=UNK"), (ex.Type, ex.Reason));
        Assert.True(ex.EntryId.EndsWith("^B-P3"), ex.EntryId);
    }

    [Fact]
    public void Reads_the_replaced_parent_document_id_from_relatedDocument_RPLC()
    {
        var doc = CcdaParser.Parse(CcdaBuilder.Build(SyntheticFeed.MarcusCcdV2));
        Assert.Equal(2, doc.Version);
        Assert.Equal($"{CcdaBuilder.DocumentRoot}^CCD-B-0001", doc.ReplacesDocumentId);
    }

    [Fact]
    public void Missing_patient_identifier_is_rejected()
    {
        var ex = Assert.Throws<CcdaValidationException>(() => CcdaParser.Parse(CcdaBuilder.Build(SyntheticFeed.MissingPatientId)));
        Assert.True(ex.Message.Contains("patient identifier"), ex.Message);
    }

    [Theory]
    [InlineData("<ClinicalDocument xmlns=\"urn:hl7-org:v3\"><id root=\"1.2\"/>", "Malformed XML")]
    [InlineData("<Bundle xmlns=\"http://hl7.org/fhir\"/>", "not hl7:ClinicalDocument")]
    [InlineData("<ClinicalDocument xmlns=\"urn:hl7-org:v3\"/>", "Missing ClinicalDocument/id")]
    public void Unusable_files_are_rejected_with_a_reason(string xml, string expectedReason)
    {
        var ex = Assert.Throws<CcdaValidationException>(() => CcdaParser.Parse(CcdaParser.LoadXml(Encoding.UTF8.GetBytes(xml))));
        Assert.True(ex.Message.Contains(expectedReason), ex.Message);
    }

    [Fact]
    public void Dtd_and_external_entities_are_refused()
    {
        const string xxe = """<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>""";
        Assert.Throws<CcdaValidationException>(() => CcdaParser.LoadXml(Encoding.UTF8.GetBytes(xxe)));
    }

    [Theory]
    [InlineData("20261103091500-0500", "2026-11-03T14:15:00Z")]
    [InlineData("20261103091500+0100", "2026-11-03T08:15:00Z")]
    [InlineData("20261103", "2026-11-03T00:00:00Z")]
    [InlineData("202611030915", "2026-11-03T09:15:00Z")]
    public void Hl7_timestamps_parse_with_offsets_and_partial_precision(string ts, string expectedUtc)
    {
        var parsed = Hl7Time.ParseInstant(ts);
        Assert.Equal(expectedUtc, parsed?.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }

    [Theory]
    [InlineData("2026")]
    [InlineData("2026-11-03")]
    [InlineData("20261399")]
    [InlineData("20261103-05")]
    public void Invalid_hl7_timestamps_return_null(string ts) => Assert.Equal(null, Hl7Time.ParseInstant(ts));
}
