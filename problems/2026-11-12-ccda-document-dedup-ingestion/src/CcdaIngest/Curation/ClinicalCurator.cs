using CcdaIngest.Model;
using CcdaIngest.Storage;

namespace CcdaIngest.Curation;

/// <summary>Curated (deduplicated) output: one row per patient and one row per clinical fact.</summary>
public sealed record CuratedSnapshot(IReadOnlyList<Patient> Patients, IReadOnlyList<CuratedEntry> Entries);

/// <summary>
/// Entry-level dedup across documents. Every CCD is a full snapshot of the patient's chart, so the
/// same diabetes problem or metformin order appears in every document the EHR sends. We keep one
/// row per clinical fact, using a natural key per entry type, and take the attributes (status,
/// dates, value) from the most recent document that mentions it.
///
/// The curated tables are a pure function of the raw ledger + manifest: they are rebuilt on every
/// run from Loaded documents only, so superseding a document (RPLC) automatically removes facts that
/// the replacement no longer contains - no in-place delete logic to get wrong.
/// </summary>
public static class ClinicalCurator
{
    /// <summary>Natural key for "the same clinical fact" within one patient.</summary>
    public static string NaturalKey(ClinicalEntry e) => e.Type switch
    {
        EntryType.Problem => $"{e.CodeSystem}|{e.Code}",                       // SNOMED concept
        EntryType.Allergy => $"{e.CodeSystem}|{e.Code}",                       // substance
        EntryType.Medication => $"{e.CodeSystem}|{e.Code}|{e.EffectiveStart}", // RxNorm + start (a restart is a new order)
        EntryType.Result => $"{e.CodeSystem}|{e.Code}|{e.EffectiveStart}",     // LOINC + specimen date
        _ => throw new ArgumentOutOfRangeException(nameof(e)),
    };

    public static CuratedSnapshot Build(IngestionState state)
    {
        var active = state.Manifest
            .Where(m => m.Status == DocumentStatus.Loaded)
            .ToDictionary(m => m.DocumentId);

        // Latest-first ordering: document time, then document id as a deterministic tie-break.
        var activeEntries = state.Entries
            .Where(e => active.ContainsKey(e.DocumentId))
            .OrderByDescending(e => e.DocumentTime, StringComparer.Ordinal)
            .ThenByDescending(e => e.DocumentId, StringComparer.Ordinal)
            .ToList();

        var entries = activeEntries
            .GroupBy(e => (e.PatientKey, e.Entry.Type, Key: NaturalKey(e.Entry)))
            .Select(g =>
            {
                var latest = g.First();
                var docs = g.Select(x => x.DocumentId).Distinct().ToList();
                return new CuratedEntry(g.Key.PatientKey, latest.Entry, docs.Count,
                    FirstSeenDocumentId: g.Last().DocumentId,
                    LastSeenDocumentId: latest.DocumentId);
            })
            .OrderBy(c => c.PatientKey, StringComparer.Ordinal)
            .ThenBy(c => c.Entry.Type)
            .ThenBy(c => NaturalKey(c.Entry), StringComparer.Ordinal)
            .ToList();

        var patients = active.Values
            .Where(m => state.PatientsByDocument.ContainsKey(m.DocumentId))
            .OrderByDescending(m => m.DocumentTime, StringComparer.Ordinal)
            .GroupBy(m => m.PatientKey)
            .Select(g => state.PatientsByDocument[g.First().DocumentId]) // demographics from the latest document
            .OrderBy(p => p.PatientKey, StringComparer.Ordinal)
            .ToList();

        return new CuratedSnapshot(patients, entries);
    }

    public static void WriteCsv(CuratedSnapshot snapshot, string folder)
    {
        Directory.CreateDirectory(folder);
        Csv.Write(Path.Combine(folder, "curated_patients.csv"),
            ["patient_key", "given_name", "family_name", "birth_date", "gender"],
            snapshot.Patients.Select(p => (IReadOnlyList<string>)[p.PatientKey, p.GivenName, p.FamilyName, p.BirthDate, p.Gender]));

        string[] header = ["patient_key", "code", "code_system", "display", "status", "effective_start", "effective_end",
                           "value", "unit", "source_document_count", "first_seen_document_id", "last_seen_document_id"];
        foreach (var type in Enum.GetValues<EntryType>())
        {
            var file = type switch
            {
                EntryType.Problem => "curated_problems.csv",
                EntryType.Medication => "curated_medications.csv",
                EntryType.Allergy => "curated_allergies.csv",
                _ => "curated_results.csv",
            };
            Csv.Write(Path.Combine(folder, file), header, snapshot.Entries.Where(c => c.Entry.Type == type).Select(c => (IReadOnlyList<string>)
                [c.PatientKey, c.Entry.Code, c.Entry.CodeSystem, c.Entry.Display, c.Entry.Status, c.Entry.EffectiveStart,
                 c.Entry.EffectiveEnd, c.Entry.Value, c.Entry.Unit, c.SourceDocumentCount.ToString(),
                 c.FirstSeenDocumentId, c.LastSeenDocumentId]));
        }
    }
}
