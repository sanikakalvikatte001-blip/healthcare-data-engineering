using CcdaIngest.Model;

namespace CcdaIngest.Ingestion;

/// <summary>The decision for one inbound file, plus which earlier document (if any) it supersedes.</summary>
public sealed record IngestionDecision(DocumentStatus Status, string Reason, string DuplicateOf = "", string? SupersedesDocumentId = null);

/// <summary>
/// In-memory index over the persistent manifest. Applies the document-level rules, in order:
///   1. raw file hash already seen          -> DuplicateFile
///   2. (parse / header validation failed)  -> RejectedInvalid   (decided by the pipeline)
///   3. canonical hash already seen         -> DuplicateContent
///   4. document id already used            -> RejectedIdConflict (same id, different content)
///   5. setId already active at version >= -> StaleVersion
///   6. setId active at a lower version     -> Loaded, older version becomes Superseded
///   7. otherwise                           -> Loaded
/// Rule order matters: a byte-identical resend of a rejected file is still just a duplicate, and an
/// id conflict is checked before versioning so a reused id can never overwrite a set.
/// </summary>
public sealed class DocumentRegistry
{
    private readonly Dictionary<string, ManifestRow> _byFileHash = new();
    private readonly Dictionary<string, ManifestRow> _byCanonicalHash = new();
    private readonly Dictionary<string, ManifestRow> _byDocumentId = new();
    private readonly Dictionary<string, ManifestRow> _activeBySet = new(); // setId -> currently Loaded row
    private readonly List<ManifestRow> _rows = [];

    public DocumentRegistry(IEnumerable<ManifestRow> existing)
    {
        foreach (var row in existing) Index(row);
    }

    public IReadOnlyList<ManifestRow> Rows => _rows;

    public IngestionDecision CheckFile(string fileSha256) =>
        _byFileHash.TryGetValue(fileSha256, out var prior)
            ? new IngestionDecision(DocumentStatus.DuplicateFile, "Byte-identical to a file already received", prior.FileName)
            : new IngestionDecision(DocumentStatus.Loaded, "");

    public IngestionDecision CheckDocument(string canonicalSha256, CcdaDocument doc)
    {
        if (_byCanonicalHash.TryGetValue(canonicalSha256, out var sameContent))
            return new(DocumentStatus.DuplicateContent, "Same canonical XML as an earlier file (re-serialized resend)", sameContent.FileName);

        if (_byDocumentId.TryGetValue(doc.DocumentId, out var sameId))
            return new(DocumentStatus.RejectedIdConflict,
                $"Document id already used by {sameId.FileName} with different content", sameId.FileName);

        if (_activeBySet.TryGetValue(doc.SetId, out var active))
        {
            if (doc.Version <= active.Version)
                return new(DocumentStatus.StaleVersion,
                    $"Version {doc.Version} arrived after version {active.Version} of the same setId", active.FileName);

            return new(DocumentStatus.Loaded, $"Replaces version {active.Version} of setId", "", active.DocumentId);
        }

        return new(DocumentStatus.Loaded, doc.Version > 1 ? $"Version {doc.Version}; earlier versions not received" : "New document");
    }

    /// <summary>Records a decided row; when it supersedes an older version, that row is flipped to Superseded.</summary>
    public void Record(ManifestRow row, string? supersedesDocumentId = null)
    {
        if (supersedesDocumentId is not null)
        {
            var index = _rows.FindIndex(r => r.DocumentId == supersedesDocumentId && r.Status == DocumentStatus.Loaded);
            if (index >= 0)
            {
                var old = _rows[index];
                var replaced = old with { Status = DocumentStatus.Superseded, Reason = $"Replaced by version {row.Version} ({row.FileName})" };
                _rows[index] = replaced;
                _byDocumentId[old.DocumentId] = replaced;
            }
        }
        Index(row);
    }

    private void Index(ManifestRow row)
    {
        _rows.Add(row);
        _byFileHash.TryAdd(row.FileSha256, row);

        // Only documents whose content we accepted (Loaded/Superseded) claim a canonical hash and a document id.
        // Rejected or stale content must not block a later, legitimate file.
        if (row.Status is DocumentStatus.Loaded or DocumentStatus.Superseded)
        {
            if (row.CanonicalSha256.Length > 0) _byCanonicalHash.TryAdd(row.CanonicalSha256, row);
            _byDocumentId.TryAdd(row.DocumentId, row);
        }
        if (row.Status == DocumentStatus.Loaded) _activeBySet[row.SetId] = row;
    }
}
