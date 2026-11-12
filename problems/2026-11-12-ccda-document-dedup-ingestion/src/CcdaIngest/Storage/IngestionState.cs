using System.Globalization;
using CcdaIngest.Model;

namespace CcdaIngest.Storage;

/// <summary>Everything that must survive between batch runs. The curated tables are always rebuilt from this.</summary>
public sealed class IngestionState
{
    public List<ManifestRow> Manifest { get; init; } = [];
    public List<DocumentEntry> Entries { get; init; } = [];
    public Dictionary<string, Patient> PatientsByDocument { get; init; } = new();
    public List<EntryException> EntryExceptions { get; init; } = [];
}

/// <summary>Persistence boundary, so the pipeline can run against files (CLI) or memory (tests).</summary>
public interface IStateStore
{
    IngestionState Load();
    void Save(IngestionState state);
}

public sealed class InMemoryStateStore : IStateStore
{
    private IngestionState _state = new();
    public IngestionState Load() => new()
    {
        Manifest = [.. _state.Manifest],
        Entries = [.. _state.Entries],
        PatientsByDocument = new(_state.PatientsByDocument),
        EntryExceptions = [.. _state.EntryExceptions],
    };
    public void Save(IngestionState state) => _state = state;
}

/// <summary>
/// CSV-backed state in a folder (ledger tables a warehouse would hold as raw/landing tables):
///   document_manifest.csv  - one row per file received, with both hashes and the decision
///   document_patients.csv  - patient header per accepted document
///   document_entries.csv   - every clinical entry per accepted document (pre-dedup)
///   entry_exceptions.csv   - entries that could not be loaded
/// </summary>
public sealed class CsvStateStore(string folder) : IStateStore
{
    private string PathOf(string name) => Path.Combine(folder, name);

    public static readonly string[] ManifestHeader =
        ["batch_id", "file_name", "file_sha256", "canonical_sha256", "document_id", "set_id", "version",
         "patient_key", "document_time", "status", "reason", "duplicate_of"];

    private static readonly string[] PatientHeader = ["document_id", "patient_key", "given_name", "family_name", "birth_date", "gender"];

    public static readonly string[] EntryHeader =
        ["document_id", "patient_key", "document_time", "entry_type", "entry_id", "code", "code_system", "display",
         "status", "effective_start", "effective_end", "value", "unit"];

    private static readonly string[] ExceptionHeader = ["document_id", "entry_type", "entry_id", "reason"];

    public IngestionState Load() => new()
    {
        Manifest = Csv.Read(PathOf("document_manifest.csv")).Select(r => new ManifestRow(
            r["batch_id"], r["file_name"], r["file_sha256"], r["canonical_sha256"], r["document_id"], r["set_id"],
            int.Parse(r["version"], CultureInfo.InvariantCulture), r["patient_key"], r["document_time"],
            Enum.Parse<DocumentStatus>(r["status"]), r["reason"], r["duplicate_of"])).ToList(),

        PatientsByDocument = Csv.Read(PathOf("document_patients.csv")).ToDictionary(
            r => r["document_id"],
            r => new Patient(r["patient_key"], r["given_name"], r["family_name"], r["birth_date"], r["gender"])),

        Entries = Csv.Read(PathOf("document_entries.csv")).Select(r => new DocumentEntry(
            r["document_id"], r["patient_key"], r["document_time"],
            new ClinicalEntry(Enum.Parse<EntryType>(r["entry_type"]), r["entry_id"], r["code"], r["code_system"],
                r["display"], r["status"], r["effective_start"], r["effective_end"], r["value"], r["unit"]))).ToList(),

        EntryExceptions = Csv.Read(PathOf("entry_exceptions.csv")).Select(r => new EntryException(
            r["document_id"], Enum.Parse<EntryType>(r["entry_type"]), r["entry_id"], r["reason"])).ToList(),
    };

    public void Save(IngestionState state)
    {
        Directory.CreateDirectory(folder);
        Csv.Write(PathOf("document_manifest.csv"), ManifestHeader, state.Manifest.Select(m => (IReadOnlyList<string>)
            [m.BatchId, m.FileName, m.FileSha256, m.CanonicalSha256, m.DocumentId, m.SetId,
             m.Version.ToString(CultureInfo.InvariantCulture), m.PatientKey, m.DocumentTime, m.Status.ToString(), m.Reason, m.DuplicateOf]));

        Csv.Write(PathOf("document_patients.csv"), PatientHeader,
            state.PatientsByDocument.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => (IReadOnlyList<string>)
                [p.Key, p.Value.PatientKey, p.Value.GivenName, p.Value.FamilyName, p.Value.BirthDate, p.Value.Gender]));

        Csv.Write(PathOf("document_entries.csv"), EntryHeader, state.Entries.Select(e => (IReadOnlyList<string>)
            [e.DocumentId, e.PatientKey, e.DocumentTime, e.Entry.Type.ToString(), e.Entry.EntryId, e.Entry.Code,
             e.Entry.CodeSystem, e.Entry.Display, e.Entry.Status, e.Entry.EffectiveStart, e.Entry.EffectiveEnd,
             e.Entry.Value, e.Entry.Unit]));

        Csv.Write(PathOf("entry_exceptions.csv"), ExceptionHeader, state.EntryExceptions.Select(x => (IReadOnlyList<string>)
            [x.DocumentId, x.Type.ToString(), x.EntryId, x.Reason]));
    }
}
