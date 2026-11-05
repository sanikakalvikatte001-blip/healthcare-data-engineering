namespace Era835Recon.Core.X12;

/// <summary>One X12 segment, e.g. <c>CLP*PCN100001*1*250*180**12*...</c>.</summary>
/// <param name="Id">Segment identifier (CLP, CAS, SVC ...).</param>
/// <param name="Elements">Elements after the identifier. Element 1 is at index 0.</param>
/// <param name="ComponentSeparator">Separator used inside composite elements (e.g. <c>HC:99213</c>).</param>
public sealed record X12Segment(string Id, IReadOnlyList<string> Elements, char ComponentSeparator)
{
    /// <summary>Returns element N using X12 numbering (CLP01 = Element(1)); empty string if absent.</summary>
    public string Element(int position) =>
        position >= 1 && position <= Elements.Count ? Elements[position - 1] : string.Empty;

    /// <summary>Splits a composite element (SVC01 = "HC:99213:25") into its components.</summary>
    public string[] Components(int position) => Element(position).Split(ComponentSeparator);
}

/// <summary>
/// Splits a raw X12 interchange into segments.
/// Delimiters are never hard-coded: they are read from the fixed-width ISA header,
/// because trading partners use different ones (~ * : are common, but not guaranteed).
/// </summary>
public static class X12Reader
{
    private const int IsaLength = 106; // ISA is always 106 characters including its terminator

    public static IReadOnlyList<X12Segment> Parse(string rawInterchange)
    {
        var text = rawInterchange.TrimStart();
        if (text.Length < IsaLength || !text.StartsWith("ISA", StringComparison.Ordinal))
            throw new FormatException("Not an X12 interchange: missing or short ISA header.");

        char elementSep = text[3];
        char componentSep = text[104];
        char segmentTerm = text[105];

        // Payers often add CR/LF after each segment or wrap at 80 characters; drop those line
        // breaks, unless the partner actually uses a newline as the segment terminator.
        if (segmentTerm != '\n') text = text.Replace("\r", string.Empty).Replace("\n", string.Empty);
        else text = text.Replace("\r", string.Empty);

        var segments = new List<X12Segment>();
        foreach (var rawSegment in text.Split(segmentTerm))
        {
            var trimmed = rawSegment.Trim();
            if (trimmed.Length == 0) continue;

            var parts = trimmed.Split(elementSep);
            segments.Add(new X12Segment(parts[0], parts.Skip(1).ToArray(), componentSep));
        }
        return segments;
    }
}
