using CcdaIngest.Curation;
using CcdaIngest.Ingestion;
using CcdaIngest.Model;
using CcdaIngest.Storage;
using CcdaIngest.Synthetic;
using Xunit;

namespace CcdaIngest.Tests;

/// <summary>Document-level rules, run through the real pipeline against an in-memory state store.</summary>
public class DocumentRuleTests
{
    private readonly IngestionPipeline _pipeline = new(new InMemoryStateStore());

    private static InboundFile File(string name, DocumentSpec spec) => new(name, CcdaBuilder.Serialize(CcdaBuilder.Build(spec)));

    private DocumentStatus Ingest(string batch, params InboundFile[] files) =>
        _pipeline.Run(batch, files).NewRows.Last().Status;

    [Fact]
    public void Byte_identical_resend_is_a_duplicate_file_and_points_at_the_original()
    {
        var original = File("a.xml", SyntheticFeed.AvaCcd);
        _pipeline.Run("b1", [original]);
        var row = _pipeline.Run("b2", [original with { FileName = "a_retry.xml" }]).NewRows.Single();

        Assert.Equal((DocumentStatus.DuplicateFile, "a.xml"), (row.Status, row.DuplicateOf));
    }

    [Fact]
    public void Reserialized_resend_is_duplicate_content()
    {
        Ingest("b1", File("a.xml", SyntheticFeed.AvaCcd));
        var gateway = new InboundFile("a_gw.xml", CcdaBuilder.SerializeAsOtherSystem(CcdaBuilder.Build(SyntheticFeed.AvaCcd)));
        Assert.Equal(DocumentStatus.DuplicateContent, Ingest("b2", gateway));
    }

    [Fact]
    public void Reused_document_id_with_different_content_is_quarantined_and_does_not_change_curated_data()
    {
        var first = _pipeline.Run("b1", [File("d.xml", SyntheticFeed.GeraldCcd)]);
        var second = _pipeline.Run("b2", [File("d2.xml", SyntheticFeed.GeraldIdConflict)]);

        Assert.Equal(DocumentStatus.RejectedIdConflict, second.NewRows.Single().Status);
        Assert.Equal("104", second.Snapshot.Entries.Single(e => e.Entry.Type == EntryType.Result).Entry.Value);
        Assert.Equal(first.Snapshot.Entries.Count, second.Snapshot.Entries.Count);
    }

    [Fact]
    public void Higher_version_replaces_the_set_and_marks_the_old_version_superseded()
    {
        Ingest("b1", File("b1.xml", SyntheticFeed.MarcusCcdV1));
        var result = _pipeline.Run("b2", [File("b2.xml", SyntheticFeed.MarcusCcdV2)]);

        var statuses = result.State.Manifest.ToDictionary(m => m.FileName, m => m.Status);
        Assert.Equal(DocumentStatus.Superseded, statuses["b1.xml"]);
        Assert.Equal(DocumentStatus.Loaded, statuses["b2.xml"]);

        // The replacement wins outright: asthma is now resolved, albuterol stopped.
        var asthma = result.Snapshot.Entries.Single(e => e.Entry.Code == "195967001");
        Assert.Equal(("completed", "2026-11-08", 1), (asthma.Entry.Status, asthma.Entry.EffectiveEnd, asthma.SourceDocumentCount));
        var albuterol = result.Snapshot.Entries.Single(e => e.Entry.Code == "745679");
        Assert.Equal("completed", albuterol.Entry.Status);
    }

    [Fact]
    public void Late_older_version_is_stale_and_cannot_roll_back_the_newer_one()
    {
        var v2 = _pipeline.Run("b1", [File("c2.xml", SyntheticFeed.PriyaCcdV2)]);
        var v1 = _pipeline.Run("b2", [File("c1.xml", SyntheticFeed.PriyaCcdV1)]);

        Assert.Equal(DocumentStatus.StaleVersion, v1.NewRows.Single().Status);
        Assert.Equal(v2.Snapshot.Entries, v1.Snapshot.Entries);
        Assert.True(v1.Snapshot.Entries.Any(e => e.Entry.Code == "433144002"), "CKD from v2 must survive the late v1");
    }

    [Fact]
    public void Same_version_resubmitted_with_new_content_is_stale_not_a_replacement()
    {
        Ingest("b1", File("a.xml", SyntheticFeed.AvaCcd));
        var sameVersionNewId = SyntheticFeed.AvaCcd with { DocumentIdExt = "CCD-A-0001b", EffectiveTime = "20261104091500-0500" };
        Assert.Equal(DocumentStatus.StaleVersion, Ingest("b2", File("a_b.xml", sameVersionNewId)));
    }

    [Fact]
    public void Truncated_file_is_rejected_and_its_byte_identical_retry_is_a_duplicate()
    {
        var bytes = CcdaBuilder.Serialize(CcdaBuilder.Build(SyntheticFeed.GeraldCcd));
        var truncated = new InboundFile("t.xml", bytes[..500]);

        Assert.Equal(DocumentStatus.RejectedInvalid, Ingest("b1", truncated));
        Assert.Equal(DocumentStatus.DuplicateFile, Ingest("b2", truncated with { FileName = "t_retry.xml" }));
        // ...and the complete file still loads: a rejected file never blocks the good one.
        Assert.Equal(DocumentStatus.Loaded, Ingest("b3", new InboundFile("t_full.xml", bytes)));
    }

    [Fact]
    public void Files_within_a_batch_are_processed_in_arrival_order()
    {
        // v2 sorts after v1 by name, so v1 loads first and is then superseded inside the same batch.
        var result = _pipeline.Run("b1", [File("2_v2.xml", SyntheticFeed.MarcusCcdV2), File("1_v1.xml", SyntheticFeed.MarcusCcdV1)]);
        var statuses = result.State.Manifest.ToDictionary(m => m.FileName, m => m.Status);
        Assert.Equal((DocumentStatus.Superseded, DocumentStatus.Loaded), (statuses["1_v1.xml"], statuses["2_v2.xml"]));
    }
}

/// <summary>Cross-document (entry-level) dedup and the end-to-end two-batch scenario.</summary>
public class CurationAndEndToEndTests
{
    private static IEnumerable<InboundFile> Batch(string name) =>
        SyntheticFeed.Build()[name].Select(f => new InboundFile(f.FileName, f.Bytes));

    [Fact]
    public void Overlapping_documents_collapse_to_one_row_per_clinical_fact_with_latest_attributes()
    {
        var pipeline = new IngestionPipeline(new InMemoryStateStore());
        pipeline.Run("b1", [new("a.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(SyntheticFeed.AvaCcd)))]);
        var snapshot = pipeline.Run("b2", [new("e.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(SyntheticFeed.AvaEncounter)))]).Snapshot;

        var ava = snapshot.Entries.Where(e => e.PatientKey.EndsWith("^100001")).ToList();
        Assert.Equal(3, ava.Count(e => e.Entry.Type == EntryType.Problem));    // DM2, HTN (both docs) + new HLD
        Assert.Equal(3, ava.Count(e => e.Entry.Type == EntryType.Medication)); // metformin, lisinopril, amlodipine
        Assert.Equal(3, ava.Count(e => e.Entry.Type == EntryType.Result));     // A1c 10-28 (both), LDL 10-28, A1c 11-10

        var lisinopril = ava.Single(e => e.Entry.Code == "314076");
        Assert.Equal(("completed", 2), (lisinopril.Entry.Status, lisinopril.SourceDocumentCount));
        Assert.True(lisinopril.FirstSeenDocumentId.EndsWith("CCD-A-0001") && lisinopril.LastSeenDocumentId.EndsWith("ENC-A-0001"),
            "first/last seen should span both documents");
    }

    [Theory]
    [InlineData("Problem|2.16.840.1.113883.6.96|44054006|20190415", "2.16.840.1.113883.6.96|44054006")]
    [InlineData("Allergy|2.16.840.1.113883.6.88|7980|20000101", "2.16.840.1.113883.6.88|7980")]
    [InlineData("Medication|2.16.840.1.113883.6.88|861007|2024-02-10", "2.16.840.1.113883.6.88|861007|2024-02-10")]
    [InlineData("Result|2.16.840.1.113883.6.1|4548-4|2026-11-10", "2.16.840.1.113883.6.1|4548-4|2026-11-10")]
    public void Natural_key_per_entry_type(string spec, string expectedKey)
    {
        var p = spec.Split('|');
        var entry = new ClinicalEntry(Enum.Parse<EntryType>(p[0]), "id", p[2], p[1], "", "", p[3], "", "", "");
        Assert.Equal(expectedKey, ClinicalCurator.NaturalKey(entry));
    }

    [Fact]
    public void Two_daily_batches_produce_the_expected_manifest_and_curated_counts()
    {
        var pipeline = new IngestionPipeline(new InMemoryStateStore());
        pipeline.Run("batch1", Batch("batch1"));
        var result = pipeline.Run("batch2", Batch("batch2"));

        var byStatus = result.State.Manifest.GroupBy(m => m.Status).ToDictionary(g => g.Key, g => g.Count());
        Assert.Equal(13, result.State.Manifest.Count);
        Assert.Equal(5, byStatus[DocumentStatus.Loaded]);
        Assert.Equal(1, byStatus[DocumentStatus.Superseded]);
        Assert.Equal(2, byStatus[DocumentStatus.DuplicateFile]);
        Assert.Equal(1, byStatus[DocumentStatus.DuplicateContent]);
        Assert.Equal(1, byStatus[DocumentStatus.StaleVersion]);
        Assert.Equal(1, byStatus[DocumentStatus.RejectedIdConflict]);
        Assert.Equal(2, byStatus[DocumentStatus.RejectedInvalid]);

        Assert.Equal(4, result.Snapshot.Patients.Count);
        Assert.Equal(27, result.Snapshot.Entries.Count);
        Assert.Equal(6, result.Snapshot.Entries.Count(e => e.SourceDocumentCount == 2));
    }

    [Fact]
    public void Replaying_a_batch_is_idempotent()
    {
        var pipeline = new IngestionPipeline(new InMemoryStateStore());
        pipeline.Run("batch1", Batch("batch1"));
        var first = pipeline.Run("batch2", Batch("batch2"));
        var replay = pipeline.Run("batch2-replay", Batch("batch2"));

        Assert.True(replay.NewRows.All(r => r.Status == DocumentStatus.DuplicateFile), "every replayed file should be a DuplicateFile");
        Assert.Equal(first.Snapshot.Entries, replay.Snapshot.Entries);
        Assert.Equal(first.Snapshot.Patients, replay.Snapshot.Patients);
        Assert.Equal(first.State.Entries.Count, replay.State.Entries.Count);
    }

    [Fact]
    public void Csv_state_store_round_trips_between_runs()
    {
        var folder = Path.Combine(Path.GetTempPath(), "ccda-ingest-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            new IngestionPipeline(new CsvStateStore(folder)).Run("batch1", Batch("batch1"));
            var csvResult = new IngestionPipeline(new CsvStateStore(folder)).Run("batch2", Batch("batch2")); // fresh process, state from disk

            var memory = new IngestionPipeline(new InMemoryStateStore());
            memory.Run("batch1", Batch("batch1"));
            var memResult = memory.Run("batch2", Batch("batch2"));

            Assert.Equal(memResult.State.Manifest.Count, csvResult.State.Manifest.Count);
            Assert.True(memResult.State.Manifest.SequenceEqual(csvResult.State.Manifest), "manifest differs after CSV round-trip");
            Assert.Equal(memResult.Snapshot.Entries, csvResult.Snapshot.Entries);
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }
}
