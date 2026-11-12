using System.Globalization;
using System.Xml.Linq;
using CcdaIngest.Model;

namespace CcdaIngest.Parsing;

/// <summary>Raised when a file is not a usable C-CDA document (bad XML, wrong root, missing header ids).</summary>
public sealed class CcdaValidationException(string message) : Exception(message);

/// <summary>
/// Extracts the header and four C-CDA R2.1 sections from a ClinicalDocument.
/// Sections are located by their LOINC section code rather than templateId, because the
/// templateId extension (date) varies by EHR vendor and C-CDA release while the LOINC code does not.
/// </summary>
public static class CcdaParser
{
    public static readonly XNamespace V3 = "urn:hl7-org:v3";
    public static readonly XNamespace Xsi = "http://www.w3.org/2001/XMLSchema-instance";

    // LOINC section codes -> entry type
    public const string ProblemSection = "11450-4";
    public const string MedicationSection = "10160-0";
    public const string AllergySection = "48765-2";
    public const string ResultSection = "30954-2";

    /// <summary>Loads XML with DTD processing disabled (XXE-safe), then parses it.</summary>
    public static XDocument LoadXml(byte[] bytes)
    {
        var settings = new System.Xml.XmlReaderSettings { DtdProcessing = System.Xml.DtdProcessing.Prohibit, XmlResolver = null };
        try
        {
            using var stream = new MemoryStream(bytes);
            using var reader = System.Xml.XmlReader.Create(stream, settings);
            return XDocument.Load(reader, LoadOptions.None);
        }
        catch (System.Xml.XmlException ex)
        {
            throw new CcdaValidationException($"Malformed XML: {ex.Message}");
        }
    }

    public static CcdaDocument Parse(XDocument xml)
    {
        var root = xml.Root;
        if (root is null || root.Name != V3 + "ClinicalDocument")
            throw new CcdaValidationException("Root element is not hl7:ClinicalDocument");

        var documentId = InstanceId(root.Element(V3 + "id"))
            ?? throw new CcdaValidationException("Missing ClinicalDocument/id");
        var setId = InstanceId(root.Element(V3 + "setId")) ?? documentId;
        var version = int.TryParse(root.Element(V3 + "versionNumber")?.Attribute("value")?.Value, out var v) ? v : 1;

        var effective = Hl7Time.ParseInstant(root.Element(V3 + "effectiveTime")?.Attribute("value")?.Value)
            ?? throw new CcdaValidationException("Missing or invalid ClinicalDocument/effectiveTime");

        var replaces = root.Elements(V3 + "relatedDocument")
            .Where(r => (string?)r.Attribute("typeCode") == "RPLC")
            .Select(r => InstanceId(r.Element(V3 + "parentDocument")?.Element(V3 + "id")))
            .FirstOrDefault(id => id is not null);

        var patient = ParsePatient(root);

        var entries = new List<ClinicalEntry>();
        var exceptions = new List<EntryException>();
        foreach (var section in root.Descendants(V3 + "section"))
        {
            var sectionCode = section.Element(V3 + "code")?.Attribute("code")?.Value;
            var sectionEntries = section.Elements(V3 + "entry");
            switch (sectionCode)
            {
                case ProblemSection: Collect(sectionEntries, EntryType.Problem, ParseProblem, documentId, entries, exceptions); break;
                case MedicationSection: Collect(sectionEntries, EntryType.Medication, ParseMedication, documentId, entries, exceptions); break;
                case AllergySection: Collect(sectionEntries, EntryType.Allergy, ParseAllergy, documentId, entries, exceptions); break;
                case ResultSection:
                    // a result entry is an organizer (panel) with one observation per component
                    var observations = sectionEntries.SelectMany(e => e.Descendants(V3 + "observation"));
                    Collect(observations, EntryType.Result, ParseResult, documentId, entries, exceptions);
                    break;
            }
        }

        return new CcdaDocument(documentId, setId, version, replaces, effective, patient, entries, exceptions);
    }

    private static Patient ParsePatient(XElement root)
    {
        var role = root.Element(V3 + "recordTarget")?.Element(V3 + "patientRole")
            ?? throw new CcdaValidationException("Missing recordTarget/patientRole");
        var patientKey = role.Elements(V3 + "id").Select(InstanceId).FirstOrDefault(id => id is not null)
            ?? throw new CcdaValidationException("Missing patient identifier (patientRole/id with root and extension)");

        var person = role.Element(V3 + "patient");
        var name = person?.Element(V3 + "name");
        return new Patient(
            patientKey,
            GivenName: string.Join(' ', name?.Elements(V3 + "given").Select(g => g.Value.Trim()) ?? []),
            FamilyName: name?.Element(V3 + "family")?.Value.Trim() ?? "",
            BirthDate: Hl7Time.ToIsoDate(person?.Element(V3 + "birthTime")?.Attribute("value")?.Value),
            Gender: person?.Element(V3 + "administrativeGenderCode")?.Attribute("code")?.Value ?? "");
    }

    // ---- entry parsers: each returns an entry, or a reason string when the entry is unusable ----

    private static (ClinicalEntry? Entry, string? Error) ParseProblem(XElement entry)
    {
        var act = entry.Element(V3 + "act");
        var obs = act?.Descendants(V3 + "observation").FirstOrDefault();
        var value = obs?.Element(V3 + "value");
        return Build(EntryType.Problem, act, value,
            status: act?.Element(V3 + "statusCode")?.Attribute("code")?.Value,
            effective: obs?.Element(V3 + "effectiveTime"));
    }

    private static (ClinicalEntry? Entry, string? Error) ParseMedication(XElement entry)
    {
        var sbadm = entry.Element(V3 + "substanceAdministration");
        var code = sbadm?.Descendants(V3 + "manufacturedMaterial").FirstOrDefault()?.Element(V3 + "code");
        return Build(EntryType.Medication, sbadm, code,
            status: sbadm?.Element(V3 + "statusCode")?.Attribute("code")?.Value,
            effective: sbadm?.Elements(V3 + "effectiveTime").FirstOrDefault(e => e.Element(V3 + "low") is not null));
    }

    private static (ClinicalEntry? Entry, string? Error) ParseAllergy(XElement entry)
    {
        var act = entry.Element(V3 + "act");
        var obs = act?.Descendants(V3 + "observation").FirstOrDefault();
        var substance = obs?.Descendants(V3 + "playingEntity").FirstOrDefault()?.Element(V3 + "code");
        return Build(EntryType.Allergy, act, substance,
            status: act?.Element(V3 + "statusCode")?.Attribute("code")?.Value,
            effective: obs?.Element(V3 + "effectiveTime"));
    }

    private static (ClinicalEntry? Entry, string? Error) ParseResult(XElement obs)
    {
        var built = Build(EntryType.Result, obs, obs.Element(V3 + "code"),
            status: obs.Element(V3 + "statusCode")?.Attribute("code")?.Value,
            effective: obs.Element(V3 + "effectiveTime"));
        if (built.Entry is null) return built;

        var value = obs.Element(V3 + "value");
        if (value is null || value.Attribute("value") is null)
            return (null, "Result observation has no value");
        return (built.Entry with { Value = value.Attribute("value")!.Value, Unit = value.Attribute("unit")?.Value ?? "" }, null);
    }

    /// <summary>Common shape: id, coded concept, status, effective low/high (or a point-in-time value).</summary>
    private static (ClinicalEntry? Entry, string? Error) Build(
        EntryType type, XElement? statement, XElement? codeElement, string? status, XElement? effective)
    {
        if (statement is null) return (null, $"{type} entry is missing its clinical statement");
        var entryId = InstanceId(statement.Element(V3 + "id")) ?? "";

        var code = codeElement?.Attribute("code")?.Value;
        var codeSystem = codeElement?.Attribute("codeSystem")?.Value;
        if (string.IsNullOrWhiteSpace(code) || string.IsNullOrWhiteSpace(codeSystem))
        {
            var nullFlavor = codeElement?.Attribute("nullFlavor")?.Value;
            return (null, nullFlavor is null ? $"{type} entry has no code" : $"{type} entry code is nullFlavor={nullFlavor}");
        }

        var start = effective?.Attribute("value")?.Value ?? effective?.Element(V3 + "low")?.Attribute("value")?.Value;
        var end = effective?.Element(V3 + "high")?.Attribute("value")?.Value;

        return (new ClinicalEntry(type, entryId, code, codeSystem,
            Display: codeElement!.Attribute("displayName")?.Value ?? "",
            Status: status ?? "",
            EffectiveStart: Hl7Time.ToIsoDate(start),
            EffectiveEnd: Hl7Time.ToIsoDate(end),
            Value: "", Unit: ""), null);
    }

    private static void Collect(
        IEnumerable<XElement> nodes, EntryType type, Func<XElement, (ClinicalEntry?, string?)> parse,
        string documentId, List<ClinicalEntry> entries, List<EntryException> exceptions)
    {
        foreach (var node in nodes)
        {
            var (entry, error) = parse(node);
            if (entry is not null) entries.Add(entry);
            else
            {
                var id = InstanceId(node.Descendants(V3 + "id").FirstOrDefault()) ?? "";
                exceptions.Add(new EntryException(documentId, type, id, error ?? "unknown"));
            }
        }
    }

    /// <summary>II data type -> "root^extension" (or just root). Null when absent or nullFlavor.</summary>
    public static string? InstanceId(XElement? id)
    {
        var root = id?.Attribute("root")?.Value;
        if (string.IsNullOrWhiteSpace(root)) return null;
        var ext = id!.Attribute("extension")?.Value;
        return string.IsNullOrWhiteSpace(ext) ? root : $"{root}^{ext}";
    }
}

/// <summary>HL7 v3 TS values: YYYY[MM[DD[HH[MM[SS]]]]][+/-ZZZZ].</summary>
public static class Hl7Time
{
    public static DateTimeOffset? ParseInstant(string? ts)
    {
        if (string.IsNullOrWhiteSpace(ts)) return null;
        var signAt = ts.IndexOfAny(['+', '-']);
        var digits = signAt >= 0 ? ts[..signAt] : ts;
        if (digits.Length < 8 || !digits.All(char.IsDigit)) return null;
        digits = digits.Length >= 14 ? digits[..14] : digits.PadRight(14, '0');

        var offset = TimeSpan.Zero;
        if (signAt >= 0)
        {
            var z = ts[(signAt + 1)..];
            if (z.Length != 4 || !z.All(char.IsDigit)) return null;
            offset = new TimeSpan(int.Parse(z[..2]), int.Parse(z[2..]), 0) * (ts[signAt] == '-' ? -1 : 1);
        }

        return DateTime.TryParseExact(digits, "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var local)
            ? new DateTimeOffset(local, offset)
            : null;
    }

    /// <summary>Date part as yyyy-MM-dd ("" when absent). Clinical dates are reported at day precision.</summary>
    public static string ToIsoDate(string? ts) =>
        ts is { Length: >= 8 } && ts[..8].All(char.IsDigit) ? $"{ts[..4]}-{ts[4..6]}-{ts[6..8]}" : "";
}
