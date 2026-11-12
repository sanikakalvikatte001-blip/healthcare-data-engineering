using System.Text;
using CcdaIngest.Curation;
using CcdaIngest.Ingestion;
using CcdaIngest.Model;
using CcdaIngest.Storage;
using CcdaIngest.Synthetic;

// Usage:
//   dotnet run --project src/CcdaIngest -- generate --inbox data/inbox
//   dotnet run --project src/CcdaIngest -- ingest   --inbox data/inbox/batch1 --batch-id batch1 --out output
var options = ParseOptions(args.Skip(1));
switch (args.FirstOrDefault())
{
    case "generate":
        var inboxRoot = options.GetValueOrDefault("inbox", "data/inbox");
        SyntheticFeed.WriteTo(inboxRoot);
        Console.WriteLine($"Wrote synthetic C-CDA drops to {inboxRoot}/batch1 and {inboxRoot}/batch2");
        return 0;

    case "ingest":
        if (!options.TryGetValue("inbox", out var inbox) || !Directory.Exists(inbox))
        {
            Console.Error.WriteLine("--inbox <folder> is required and must exist");
            return 2;
        }
        var outDir = options.GetValueOrDefault("out", "output");
        var batchId = options.GetValueOrDefault("batch-id", Path.GetFileName(Path.TrimEndingDirectorySeparator(inbox)));

        var files = Directory.GetFiles(inbox, "*.xml").Select(p => new InboundFile(Path.GetFileName(p), File.ReadAllBytes(p)));
        var result = new IngestionPipeline(new CsvStateStore(Path.Combine(outDir, "state"))).Run(batchId, files);
        ClinicalCurator.WriteCsv(result.Snapshot, Path.Combine(outDir, "curated"));

        var report = Report(result);
        File.WriteAllText(Path.Combine(outDir, $"run_summary_{batchId}.txt"), report);
        Console.Write(report);
        return 0;

    default:
        Console.Error.WriteLine("Commands: generate [--inbox dir] | ingest --inbox dir [--batch-id id] [--out dir]");
        return 2;
}

static Dictionary<string, string> ParseOptions(IEnumerable<string> args)
{
    var list = args.ToList();
    var options = new Dictionary<string, string>();
    for (int i = 0; i + 1 < list.Count; i += 2)
        if (list[i].StartsWith("--")) options[list[i][2..]] = list[i + 1];
    return options;
}

static string Report(BatchResult result)
{
    var sb = new StringBuilder();
    var manifest = result.State.Manifest;
    sb.AppendLine($"=== C-CDA ingestion: {result.BatchId} ===");
    sb.AppendLine($"{"file",-30} {"status",-19} {"document_id",-48} reason");
    foreach (var row in manifest.Where(m => m.BatchId == result.BatchId))
        sb.AppendLine($"{row.FileName,-30} {row.Status,-19} {row.DocumentId,-48} {row.Reason}");

    sb.AppendLine();
    sb.AppendLine("Manifest (all batches) by status:");
    foreach (var g in manifest.GroupBy(m => m.Status).OrderBy(g => g.Key))
        sb.AppendLine($"  {g.Key,-19} {g.Count(),3}");

    var raw = result.State.Entries.Count(e => manifest.Any(m => m.DocumentId == e.DocumentId && m.Status == DocumentStatus.Loaded));
    sb.AppendLine();
    sb.AppendLine($"Active documents: {manifest.Count(m => m.Status == DocumentStatus.Loaded)}; " +
                  $"raw entries in active documents: {raw}; curated entries: {result.Snapshot.Entries.Count} " +
                  $"({raw - result.Snapshot.Entries.Count} cross-document duplicates collapsed)");
    sb.AppendLine($"Curated patients: {result.Snapshot.Patients.Count}");
    foreach (var type in Enum.GetValues<EntryType>())
        sb.AppendLine($"  {type,-10} {result.Snapshot.Entries.Count(e => e.Entry.Type == type),3}");
    sb.AppendLine($"Entry exceptions (all batches): {result.State.EntryExceptions.Count}");
    return sb.ToString();
}
