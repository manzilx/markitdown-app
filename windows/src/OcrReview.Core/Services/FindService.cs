using System.Text;
using OcrReview.Core.Models;

namespace OcrReview.Core.Services;

public static class FindService
{
    public static List<FindMatch> Find(OcrDocument document, string query, bool caseSensitive = false)
    {
        var trimmed = query.Trim();
        var matches = new List<FindMatch>();
        if (trimmed.Length == 0) return matches;

        var cmp = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        foreach (var page in document.Pages.OrderBy(p => p.PageNumber))
        {
            var text = page.DisplayText;
            int idx = 0;
            while (idx <= text.Length)
            {
                int found = text.IndexOf(trimmed, idx, cmp);
                if (found < 0) break;
                matches.Add(new FindMatch
                {
                    PageNumber = page.PageNumber,
                    Start = found,
                    Length = trimmed.Length,
                    Snippet = Snippet(text, found, trimmed.Length),
                });
                idx = found + Math.Max(trimmed.Length, 1);
            }
        }
        return matches;
    }

    public static string ReplaceAt(string text, int start, int length, string replacement)
    {
        if (start < 0 || start + length > text.Length) return text;
        return string.Concat(text.AsSpan(0, start), replacement, text.AsSpan(start + length));
    }

    public static string ReplaceAll(string text, string query, string replacement, bool caseSensitive = false)
    {
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return text;

        var cmp = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var sb = new StringBuilder();
        int idx = 0;
        while (true)
        {
            int found = text.IndexOf(trimmed, idx, cmp);
            if (found < 0)
            {
                sb.Append(text, idx, text.Length - idx);
                break;
            }
            sb.Append(text, idx, found - idx);
            sb.Append(replacement);
            idx = found + trimmed.Length;
        }
        return sb.ToString();
    }

    private static string Snippet(string text, int start, int length, int radius = 24)
    {
        int from = Math.Max(0, start - radius);
        int toExclusive = Math.Min(text.Length, start + length + radius);
        var snippet = text.Substring(from, toExclusive - from).Replace('\n', ' ');
        if (from > 0) snippet = "…" + snippet;
        if (toExclusive < text.Length) snippet += "…";
        return snippet;
    }
}
