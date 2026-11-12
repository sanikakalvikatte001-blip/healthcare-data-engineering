namespace CcdaIngest.Model;

/// <summary>Clinical entry types extracted from the four C-CDA sections we load.</summary>
public enum EntryType { Problem, Medication, Allergy, Result }

/// <summary>Outcome of the document-level ingestion decision. Only <see cref="Loaded"/> documents feed the curated tables.</summary>
public enum DocumentStatus
{
    Loaded,             // new document (or a newer version of a known set) - its entries are active
    Superseded,         // was Loaded, later replaced by a higher version of the same setId (RPLC)
    DuplicateFile,      // byte-identical to a file already received (same SHA-256 of raw bytes)
    DuplicateContent,   // different bytes, same canonical XML (re-serialized / pretty-printed resend)
    StaleVersion,       // late-arriving older (or equal) version of a set we already hold a newer version of
    RejectedIdConflict, // document id already used by a document with different content - quarantine
    RejectedInvalid,    // not well-formed XML, not a ClinicalDocument, or missing required header ids
}

/// <summary>Patient demographics from recordTarget/patientRole. PatientKey = assigningAuthorityOid^MRN.</summary>
public sealed record Patient(string PatientKey, string GivenName, string FamilyName, string BirthDate, string Gender);

/// <summary>
/// One clinical statement, flattened to a common shape so all four entry types share one raw table.
/// Code/CodeSystem identify the clinical concept (SNOMED problem, RxNorm drug/substance, LOINC test).
/// </summary>
public sealed record ClinicalEntry(
    EntryType Type,
    string EntryId,
    string Code,
    string CodeSystem,
    string Display,
    string Status,
    string EffectiveStart,
    string EffectiveEnd,
    string Value,
    string Unit);

/// <summary>An entry we could not load (e.g. nullFlavor code) - kept for data-quality follow-up, never silently dropped.</summary>
public sealed record EntryException(string DocumentId, EntryType Type, string EntryId, string Reason);

/// <summary>Header + body of one parsed C-CDA document.</summary>
public sealed record CcdaDocument(
    string DocumentId,       // ClinicalDocument/id  root^extension
    string SetId,            // ClinicalDocument/setId root^extension (falls back to DocumentId)
    int Version,             // ClinicalDocument/versionNumber/@value (defaults to 1)
    string? ReplacesDocumentId, // relatedDocument[@typeCode='RPLC']/parentDocument/id
    DateTimeOffset EffectiveTime,
    Patient Patient,
    IReadOnlyList<ClinicalEntry> Entries,
    IReadOnlyList<EntryException> Exceptions);

/// <summary>One row of the persistent document manifest - the audit trail of every file ever received.</summary>
public sealed record ManifestRow(
    string BatchId,
    string FileName,
    string FileSha256,
    string CanonicalSha256,
    string DocumentId,
    string SetId,
    int Version,
    string PatientKey,
    string DocumentTime,
    DocumentStatus Status,
    string Reason,
    string DuplicateOf);

/// <summary>A raw entry tied to the document (and patient) it came from.</summary>
public sealed record DocumentEntry(string DocumentId, string PatientKey, string DocumentTime, ClinicalEntry Entry);

/// <summary>A deduplicated clinical fact across all active documents for a patient.</summary>
public sealed record CuratedEntry(
    string PatientKey,
    ClinicalEntry Entry,
    int SourceDocumentCount,
    string FirstSeenDocumentId,
    string LastSeenDocumentId);
