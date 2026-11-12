using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace CcdaIngest.Hashing;

/// <summary>
/// Two fingerprints per inbound file:
///  1. FileSha256      - SHA-256 of the raw bytes. Catches exact resends (HIE retries, SFTP re-drops).
///  2. CanonicalSha256 - SHA-256 of a canonical form of the XML. Catches the same document re-serialized
///                       by another system: different indentation, line endings, attribute order,
///                       comments, XML declaration or encoding, but identical clinical content.
/// The canonical form is a pragmatic subset of W3C C14N that is enough for C-CDA resends:
/// comments and processing instructions removed, whitespace-only text dropped, other text
/// whitespace-collapsed, attributes sorted by (namespace, name), namespace declarations ignored
/// (element/attribute names are compared by their resolved namespace URI, not prefix).
/// </summary>
public static partial class DocumentFingerprint
{
    public static string FileSha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    public static string CanonicalSha256(XDocument document)
    {
        var sb = new StringBuilder();
        if (document.Root is not null) WriteCanonical(document.Root, sb);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()))).ToLowerInvariant();
    }

    /// <summary>The canonical text itself - exposed so tests (and humans) can see what is hashed.</summary>
    public static string CanonicalText(XDocument document)
    {
        var sb = new StringBuilder();
        if (document.Root is not null) WriteCanonical(document.Root, sb);
        return sb.ToString();
    }

    private static void WriteCanonical(XElement element, StringBuilder sb)
    {
        sb.Append('<').Append(QualifiedName(element.Name));

        var attributes = element.Attributes()
            .Where(a => !a.IsNamespaceDeclaration)
            .OrderBy(a => a.Name.NamespaceName, StringComparer.Ordinal)
            .ThenBy(a => a.Name.LocalName, StringComparer.Ordinal);
        foreach (var a in attributes)
            sb.Append(' ').Append(QualifiedName(a.Name)).Append("=\"").Append(Escape(Collapse(a.Value))).Append('"');
        sb.Append('>');

        foreach (var node in element.Nodes())
        {
            switch (node)
            {
                case XElement child:
                    WriteCanonical(child, sb);
                    break;
                case XText text: // includes CDATA
                    var collapsed = Collapse(text.Value);
                    if (collapsed.Length > 0) sb.Append(Escape(collapsed));
                    break;
                // XComment and XProcessingInstruction are deliberately skipped
            }
        }

        sb.Append("</").Append(QualifiedName(element.Name)).Append('>');
    }

    private static string QualifiedName(XName name) =>
        name.NamespaceName.Length == 0 ? name.LocalName : "{" + name.NamespaceName + "}" + name.LocalName;

    private static string Collapse(string value) => Whitespace().Replace(value, " ").Trim();

    private static string Escape(string value) =>
        value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();
}
