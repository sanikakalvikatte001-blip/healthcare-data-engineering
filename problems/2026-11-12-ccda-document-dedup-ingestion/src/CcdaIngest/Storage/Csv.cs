using System.Text;

namespace CcdaIngest.Storage;

/// <summary>Minimal RFC 4180 CSV reader/writer (quoted fields, embedded commas, quotes and newlines).</summary>
public static class Csv
{
    public static void Write(string path, IReadOnlyList<string> header, IEnumerable<IReadOnlyList<string>> rows)
    {
        var sb = new StringBuilder();
        sb.Append(string.Join(',', header.Select(Quote))).Append('\n');
        foreach (var row in rows) sb.Append(string.Join(',', row.Select(Quote))).Append('\n');
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
    }

    /// <summary>Returns rows as dictionaries keyed by header name. A missing file reads as empty.</summary>
    public static List<Dictionary<string, string>> Read(string path)
    {
        if (!File.Exists(path)) return [];
        var records = Parse(File.ReadAllText(path));
        if (records.Count == 0) return [];
        var header = records[0];
        return records.Skip(1)
            .Select(r => header.Select((h, i) => (h, v: i < r.Count ? r[i] : "")).ToDictionary(x => x.h, x => x.v))
            .ToList();
    }

    private static string Quote(string value) =>
        value.IndexOfAny([',', '"', '\n', '\r']) >= 0 ? "\"" + value.Replace("\"", "\"\"") + "\"" : value;

    private static List<List<string>> Parse(string text)
    {
        var records = new List<List<string>>();
        var record = new List<string>();
        var field = new StringBuilder();
        bool inQuotes = false;

        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (inQuotes)
            {
                if (c == '"' && i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                else if (c == '"') inQuotes = false;
                else field.Append(c);
            }
            else if (c == '"') inQuotes = true;
            else if (c == ',') { record.Add(field.ToString()); field.Clear(); }
            else if (c == '\n')
            {
                record.Add(field.ToString()); field.Clear();
                records.Add(record); record = [];
            }
            else if (c != '\r') field.Append(c);
        }
        if (field.Length > 0 || record.Count > 0) { record.Add(field.ToString()); records.Add(record); }
        return records;
    }
}
