using System.Text;
using System.Xml;
using System.Xml.Linq;
using CcdaIngest.Parsing;

namespace CcdaIngest.Synthetic;

// Small spec types used only to build synthetic documents.
public sealed record PatientSpec(string Mrn, string Given, string Family, string BirthDate, string Gender);
public sealed record CodedItem(string Id, string Code, string Display, string Status, string Start, string End = "");
public sealed record ResultItem(string Id, string Loinc, string Display, string Date, string Value, string Unit);

public sealed record DocumentSpec(
    string DocumentIdExt, string SetIdExt, int Version, string? ReplacesIdExt, string EffectiveTime,
    PatientSpec? Patient, string Title,
    IReadOnlyList<CodedItem> Problems, IReadOnlyList<CodedItem> Medications,
    IReadOnlyList<CodedItem> Allergies, IReadOnlyList<ResultItem> Results);

/// <summary>
/// Builds C-CDA R2.1-shaped ClinicalDocuments (header + Problems, Medications, Allergies, Results).
/// OIDs are under 2.16.840.1.113883.19, the HL7 example root, so nothing looks like a real facility.
/// </summary>
public static class CcdaBuilder
{
    private static readonly XNamespace V3 = CcdaParser.V3;
    private static readonly XNamespace Xsi = CcdaParser.Xsi;

    public const string DocumentRoot = "2.16.840.1.113883.19.5.99999.1";
    public const string MrnRoot = "2.16.840.1.113883.19.5.99999.2";
    private const string EntryRoot = "2.16.840.1.113883.19.5.99999.3";
    private const string Snomed = "2.16.840.1.113883.6.96";
    private const string RxNorm = "2.16.840.1.113883.6.88";
    private const string Loinc = "2.16.840.1.113883.6.1";

    public static XDocument Build(DocumentSpec d)
    {
        var header = new List<object>
        {
            new XAttribute(XNamespace.Xmlns + "xsi", Xsi),
            new XElement(V3 + "realmCode", new XAttribute("code", "US")),
            new XElement(V3 + "typeId", new XAttribute("root", "2.16.840.1.113883.1.3"), new XAttribute("extension", "POCD_HD000040")),
            Template("2.16.840.1.113883.10.20.22.1.1", "2015-08-01"),   // US Realm Header
            Template("2.16.840.1.113883.10.20.22.1.2", "2015-08-01"),   // CCD
            Id(DocumentRoot, d.DocumentIdExt),
            new XElement(V3 + "code", new XAttribute("code", "34133-9"), new XAttribute("codeSystem", Loinc),
                new XAttribute("displayName", "Summarization of Episode Note")),
            new XElement(V3 + "title", d.Title),
            new XElement(V3 + "effectiveTime", new XAttribute("value", d.EffectiveTime)),
            new XElement(V3 + "confidentialityCode", new XAttribute("code", "N"), new XAttribute("codeSystem", "2.16.840.1.113883.5.25")),
            new XElement(V3 + "languageCode", new XAttribute("code", "en-US")),
            new XElement(V3 + "setId", new XAttribute("root", DocumentRoot), new XAttribute("extension", d.SetIdExt)),
            new XElement(V3 + "versionNumber", new XAttribute("value", d.Version)),
            new XElement(V3 + "recordTarget", new XElement(V3 + "patientRole", PatientContent(d.Patient))),
        };

        if (d.ReplacesIdExt is not null)
            header.Add(new XElement(V3 + "relatedDocument", new XAttribute("typeCode", "RPLC"),
                new XElement(V3 + "parentDocument", Id(DocumentRoot, d.ReplacesIdExt))));

        var body = new XElement(V3 + "component", new XElement(V3 + "structuredBody",
            Section("2.16.840.1.113883.10.20.22.2.5.1", CcdaParser.ProblemSection, "Problems", d.Problems.Select(ProblemEntry), Narrative(d.Problems)),
            Section("2.16.840.1.113883.10.20.22.2.1.1", CcdaParser.MedicationSection, "Medications", d.Medications.Select(MedicationEntry), Narrative(d.Medications)),
            Section("2.16.840.1.113883.10.20.22.2.6.1", CcdaParser.AllergySection, "Allergies and Intolerances", d.Allergies.Select(AllergyEntry), Narrative(d.Allergies)),
            Section("2.16.840.1.113883.10.20.22.2.3.1", CcdaParser.ResultSection, "Results", d.Results.Select(ResultEntry),
                string.Join("; ", d.Results.Select(r => $"{r.Display} {r.Value} {r.Unit} ({r.Date})")))));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null),
            new XElement(V3 + "ClinicalDocument", header, body));
    }

    private static IEnumerable<object> PatientContent(PatientSpec? p)
    {
        if (p is null) // a real-world defect: patientRole present but no identifier
        {
            yield return new XElement(V3 + "id", new XAttribute("nullFlavor", "NI"));
            yield break;
        }
        yield return Id(MrnRoot, p.Mrn);
        yield return new XElement(V3 + "patient",
            new XElement(V3 + "name", new XAttribute("use", "L"), new XElement(V3 + "given", p.Given), new XElement(V3 + "family", p.Family)),
            new XElement(V3 + "administrativeGenderCode", new XAttribute("code", p.Gender), new XAttribute("codeSystem", "2.16.840.1.113883.5.1")),
            new XElement(V3 + "birthTime", new XAttribute("value", p.BirthDate)));
    }

    private static XElement Section(string templateId, string loinc, string title, IEnumerable<XElement> entries, string narrative) =>
        new(V3 + "component", new XElement(V3 + "section",
            Template(templateId, "2015-08-01"),
            new XElement(V3 + "code", new XAttribute("code", loinc), new XAttribute("codeSystem", Loinc)),
            new XElement(V3 + "title", title),
            new XElement(V3 + "text", new XElement(V3 + "paragraph", narrative)),
            entries));

    private static string Narrative(IEnumerable<CodedItem> items) =>
        string.Join("; ", items.Select(i => $"{i.Display} ({i.Status})"));

    private static XElement ProblemEntry(CodedItem p) =>
        new(V3 + "entry", new XAttribute("typeCode", "DRIV"),
            new XElement(V3 + "act", new XAttribute("classCode", "ACT"), new XAttribute("moodCode", "EVN"),
                Template("2.16.840.1.113883.10.20.22.4.3", "2015-08-01"),
                Id(EntryRoot, p.Id),
                new XElement(V3 + "code", new XAttribute("code", "CONC"), new XAttribute("codeSystem", "2.16.840.1.113883.5.6")),
                new XElement(V3 + "statusCode", new XAttribute("code", p.Status)),
                Interval(p.Start, ""),
                new XElement(V3 + "entryRelationship", new XAttribute("typeCode", "SUBJ"),
                    new XElement(V3 + "observation", new XAttribute("classCode", "OBS"), new XAttribute("moodCode", "EVN"),
                        Template("2.16.840.1.113883.10.20.22.4.4", "2015-08-01"),
                        Id(EntryRoot, p.Id + "-obs"),
                        new XElement(V3 + "code", new XAttribute("code", "55607006"), new XAttribute("codeSystem", Snomed), new XAttribute("displayName", "Problem")),
                        new XElement(V3 + "statusCode", new XAttribute("code", "completed")),
                        Interval(p.Start, p.End),
                        Coded("value", p.Code, Snomed, p.Display, xsiType: "CD")))));

    private static XElement MedicationEntry(CodedItem m) =>
        new(V3 + "entry", new XAttribute("typeCode", "DRIV"),
            new XElement(V3 + "substanceAdministration", new XAttribute("classCode", "SBADM"), new XAttribute("moodCode", "INT"),
                Template("2.16.840.1.113883.10.20.22.4.16", "2014-06-09"),
                Id(EntryRoot, m.Id),
                new XElement(V3 + "statusCode", new XAttribute("code", m.Status)),
                Interval(m.Start, m.End, xsiType: "IVL_TS"),
                new XElement(V3 + "consumable",
                    new XElement(V3 + "manufacturedProduct", new XAttribute("classCode", "MANU"),
                        Template("2.16.840.1.113883.10.20.22.4.23", "2014-06-09"),
                        new XElement(V3 + "manufacturedMaterial", Coded("code", m.Code, RxNorm, m.Display))))));

    private static XElement AllergyEntry(CodedItem a) =>
        new(V3 + "entry", new XAttribute("typeCode", "DRIV"),
            new XElement(V3 + "act", new XAttribute("classCode", "ACT"), new XAttribute("moodCode", "EVN"),
                Template("2.16.840.1.113883.10.20.22.4.30", "2015-08-01"),
                Id(EntryRoot, a.Id),
                new XElement(V3 + "code", new XAttribute("code", "CONC"), new XAttribute("codeSystem", "2.16.840.1.113883.5.6")),
                new XElement(V3 + "statusCode", new XAttribute("code", a.Status)),
                new XElement(V3 + "entryRelationship", new XAttribute("typeCode", "SUBJ"),
                    new XElement(V3 + "observation", new XAttribute("classCode", "OBS"), new XAttribute("moodCode", "EVN"),
                        Template("2.16.840.1.113883.10.20.22.4.7", "2014-06-09"),
                        Id(EntryRoot, a.Id + "-obs"),
                        new XElement(V3 + "code", new XAttribute("code", "ASSERTION"), new XAttribute("codeSystem", "2.16.840.1.113883.5.4")),
                        new XElement(V3 + "statusCode", new XAttribute("code", "completed")),
                        Interval(a.Start, ""),
                        Coded("value", "419511003", Snomed, "Propensity to adverse reactions to drug", xsiType: "CD"),
                        new XElement(V3 + "participant", new XAttribute("typeCode", "CSM"),
                            new XElement(V3 + "participantRole", new XAttribute("classCode", "MANU"),
                                new XElement(V3 + "playingEntity", new XAttribute("classCode", "MMAT"),
                                    Coded("code", a.Code, RxNorm, a.Display))))))));

    private static XElement ResultEntry(ResultItem r) =>
        new(V3 + "entry", new XAttribute("typeCode", "DRIV"),
            new XElement(V3 + "organizer", new XAttribute("classCode", "BATTERY"), new XAttribute("moodCode", "EVN"),
                Template("2.16.840.1.113883.10.20.22.4.1", "2015-08-01"),
                Id(EntryRoot, r.Id + "-panel"),
                new XElement(V3 + "code", new XAttribute("code", "26436-6"), new XAttribute("codeSystem", Loinc), new XAttribute("displayName", "Laboratory studies")),
                new XElement(V3 + "statusCode", new XAttribute("code", "completed")),
                new XElement(V3 + "component",
                    new XElement(V3 + "observation", new XAttribute("classCode", "OBS"), new XAttribute("moodCode", "EVN"),
                        Template("2.16.840.1.113883.10.20.22.4.2", "2015-08-01"),
                        Id(EntryRoot, r.Id),
                        Coded("code", r.Loinc, Loinc, r.Display),
                        new XElement(V3 + "statusCode", new XAttribute("code", "completed")),
                        new XElement(V3 + "effectiveTime", new XAttribute("value", r.Date)),
                        new XElement(V3 + "value", new XAttribute(Xsi + "type", "PQ"), new XAttribute("value", r.Value), new XAttribute("unit", r.Unit))))));

    private static XElement Template(string root, string ext) =>
        new(V3 + "templateId", new XAttribute("root", root), new XAttribute("extension", ext));

    private static XElement Id(string root, string ext) =>
        new(V3 + "id", new XAttribute("root", root), new XAttribute("extension", ext));

    /// <summary>A coded element; an empty code is emitted as nullFlavor="UNK" (a common EHR export defect).</summary>
    private static XElement Coded(string name, string code, string system, string display, string? xsiType = null)
    {
        var e = new XElement(V3 + name);
        if (xsiType is not null) e.Add(new XAttribute(Xsi + "type", xsiType));
        if (code.Length == 0) e.Add(new XAttribute("nullFlavor", "UNK"));
        else e.Add(new XAttribute("code", code), new XAttribute("codeSystem", system), new XAttribute("displayName", display));
        return e;
    }

    private static XElement Interval(string low, string high, string? xsiType = null)
    {
        var e = new XElement(V3 + "effectiveTime");
        if (xsiType is not null) e.Add(new XAttribute(Xsi + "type", xsiType));
        e.Add(new XElement(V3 + "low", new XAttribute("value", low)));
        if (high.Length > 0) e.Add(new XElement(V3 + "high", new XAttribute("value", high)));
        return e;
    }

    /// <summary>Standard serialization: 2-space indent, LF line endings, UTF-8 without BOM.</summary>
    public static byte[] Serialize(XDocument doc)
    {
        var settings = new XmlWriterSettings { Indent = true, IndentChars = "  ", NewLineChars = "\n", Encoding = new UTF8Encoding(false) };
        using var ms = new MemoryStream();
        using (var writer = XmlWriter.Create(ms, settings)) doc.Save(writer);
        return ms.ToArray();
    }

    /// <summary>
    /// The same document as another system would re-emit it: attribute order reversed, tab indent,
    /// CRLF line endings, a generator comment and a processing instruction. Clinically identical.
    /// </summary>
    public static byte[] SerializeAsOtherSystem(XDocument doc)
    {
        var copy = new XDocument(doc);
        foreach (var element in copy.Descendants())
        {
            var reordered = element.Attributes().Where(a => !a.IsNamespaceDeclaration).Reverse().ToList();
            var declarations = element.Attributes().Where(a => a.IsNamespaceDeclaration).ToList();
            element.ReplaceAttributes(declarations.Concat(reordered));
        }
        copy.AddFirst(new XProcessingInstruction("xml-stylesheet", "type=\"text/xsl\" href=\"CDA.xsl\""));
        copy.Root!.AddFirst(new XComment(" Re-sent by HIE gateway (retry 2) "));

        var settings = new XmlWriterSettings { Indent = true, IndentChars = "\t", NewLineChars = "\r\n", Encoding = new UTF8Encoding(true) };
        using var ms = new MemoryStream();
        using (var writer = XmlWriter.Create(ms, settings)) copy.Save(writer);
        return ms.ToArray();
    }
}
