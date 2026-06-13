using System.Text;
using OcrReview.Core.Models;

namespace OcrReview.Core.Services;

public static class ExportService
{
    public static string Markdown(OcrDocument document, int totalPages)
    {
        var parts = new List<string> { $"# {document.Filename}", "" };
        foreach (var page in document.Pages.OrderBy(p => p.PageNumber))
        {
            if (totalPages > 1)
            {
                parts.Add($"## Page {page.PageNumber}");
                parts.Add("");
            }
            parts.Add(page.ExportText);
            parts.Add("");
        }
        if (document.Pages.Count < totalPages)
        {
            parts.Add($"<!-- Exported {document.Pages.Count} of {totalPages} pages (OCR not run on all pages) -->");
            parts.Add("");
        }
        return string.Join("\n", parts).Trim() + "\n";
    }

    public static string PlainText(OcrDocument document, int totalPages)
    {
        var parts = new List<string>();
        foreach (var page in document.Pages.OrderBy(p => p.PageNumber))
        {
            if (totalPages > 1)
            {
                parts.Add($"Page {page.PageNumber}");
                parts.Add("");
            }
            parts.Add(page.ExportText);
            parts.Add("");
        }
        return string.Join("\n", parts).Trim() + "\n";
    }

    /// <summary>Minimal, valid RTF with a title, page headers, and body text.</summary>
    public static string Rtf(OcrDocument document, int totalPages)
    {
        var sb = new StringBuilder();
        sb.Append(@"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fnil Segoe UI;}}");
        sb.Append(@"\viewkind4\uc1\pard\sa180");
        sb.Append(@"\fs36\b ").Append(EscapeRtf(document.Filename)).Append(@"\b0\par");

        foreach (var page in document.Pages.OrderBy(p => p.PageNumber))
        {
            if (totalPages > 1)
                sb.Append(@"\fs26\b Page ").Append(page.PageNumber).Append(@"\b0\par");

            sb.Append(@"\fs22 ");
            var lines = page.ExportText.Replace("\r\n", "\n").Split('\n');
            for (int i = 0; i < lines.Length; i++)
            {
                sb.Append(EscapeRtf(lines[i]));
                sb.Append(@"\par");
            }
        }

        sb.Append('}');
        return sb.ToString();
    }

    private static string EscapeRtf(string input)
    {
        var sb = new StringBuilder(input.Length);
        foreach (var c in input)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '{': sb.Append(@"\{"); break;
                case '}': sb.Append(@"\}"); break;
                default:
                    if (c > 127)
                        sb.Append(@"\u").Append((int)c).Append('?');
                    else
                        sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }
}
