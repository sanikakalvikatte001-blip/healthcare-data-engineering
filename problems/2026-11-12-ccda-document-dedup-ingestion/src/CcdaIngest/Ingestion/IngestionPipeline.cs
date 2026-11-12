using System.Globalization;
using CcdaIngest.Curation;
using CcdaIngest.Hashing;
using CcdaIngest.Model;
using CcdaIngest.Parsing;
using CcdaIngest.Storage;

namespace CcdaIngest.Ingestion;

/// <summary>One inbound file: name as dropped by the HIE / SFTP feed, and its raw bytes.</summary>
public sealed record InboundFile(string FileName, byte[] Bytes);

/// <summary>What one batch run did: the manifest rows it added and the rebuilt curated snapshot.</summary>
public sealed record BatchResult(string BatchId, IReadOnlyList<ManifestRow> NewRows, CuratedSnapshot Snapshot, IngestionState State);

/// <summary>
/// Batch ingestion of a C-CDA drop folder:
///   hash raw bytes -> parse + validate -> canonical hash -> document rules -> stage entries -> rebuild curated.
/// The run is idempotent: replaying a batch only produces DuplicateFile rows and leaves the curated
/// tables unchanged. State is loaded once and saved once, so a crash mid-batch leaves the previous
/// state intact (the whole batch is simply re-run).
/// </summary>
public sealed class IngestionPipeline(IStateStore store)
{
    public BatchResult Run(string batchId, IEnumerable<InboundFile> files)
    {
        var state = store.Load();
        var registry = new DocumentRegistry(state.Manifest);
        var newRows = new List<ManifestRow>();

        // Process in file-name order, which for these feeds encodes arrival order.
        foreach (var file in files.OrderBy(f => f.FileName, StringComparer.Ordinal))
        {
            var row = Process(batchId, file, registry, state, out var supersedes);
            registry.Record(row, supersedes);
            newRows.Add(row);
        }

        var finalState = new IngestionState
        {
            Manifest = [.. registry.Rows],
            Entries = state.Entries,
            PatientsByDocument = state.PatientsByDocument,
            EntryExceptions = state.EntryExceptions,
        };
        store.Save(finalState);
        return new BatchResult(batchId, newRows, ClinicalCurator.Build(finalState), finalState);
    }

    private static ManifestRow Process(string batchId, InboundFile file, DocumentRegistry registry, IngestionState state, out string? supersedes)
    {
        supersedes = null;
        var fileHash = DocumentFingerprint.FileSha256(file.Bytes);
        ManifestRow Row(DocumentStatus status, string reason, string duplicateOf = "", string canonical = "", CcdaDocument? doc = null) =>
            new(batchId, file.FileName, fileHash, canonical,
                doc?.DocumentId ?? "", doc?.SetId ?? "", doc?.Version ?? 0, doc?.Patient.PatientKey ?? "",
                doc is null ? "" : doc.EffectiveTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
                status, reason, duplicateOf);

        // 1. Exact resend - cheapest check, no parsing needed.
        var fileCheck = registry.CheckFile(fileHash);
        if (fileCheck.Status == DocumentStatus.DuplicateFile)
            return Row(fileCheck.Status, fileCheck.Reason, fileCheck.DuplicateOf);

        // 2. Parse and validate the header; anything unusable is quarantined with the reason.
        CcdaDocument doc;
        string canonicalHash;
        try
        {
            var xml = CcdaParser.LoadXml(file.Bytes);
            canonicalHash = DocumentFingerprint.CanonicalSha256(xml);
            doc = CcdaParser.Parse(xml);
        }
        catch (CcdaValidationException ex)
        {
            return Row(DocumentStatus.RejectedInvalid, ex.Message);
        }

        // 3-6. Content / identity / version rules.
        var decision = registry.CheckDocument(canonicalHash, doc);
        if (decision.Status != DocumentStatus.Loaded)
            return Row(decision.Status, decision.Reason, decision.DuplicateOf, canonicalHash, doc);

        // 7. Accepted: stage the patient header, entries and entry-level exceptions.
        var row = Row(DocumentStatus.Loaded, decision.Reason, "", canonicalHash, doc);
        state.PatientsByDocument[doc.DocumentId] = doc.Patient;
        state.Entries.AddRange(doc.Entries.Select(e => new DocumentEntry(doc.DocumentId, doc.Patient.PatientKey, row.DocumentTime, e)));
        state.EntryExceptions.AddRange(doc.Exceptions);
        supersedes = decision.SupersedesDocumentId;
        return row;
    }
}
