using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace OcrReview.App.Services;

/// <summary>Structural PDF edits via PdfSharp. Each operation writes a new file.</summary>
public static class PdfEditService
{
    public static void Rotate(string srcPath, int pageIndex, bool clockwise, string outPath)
    {
        using var doc = PdfReader.Open(srcPath, PdfDocumentOpenMode.Modify);
        if (pageIndex < 0 || pageIndex >= doc.PageCount) return;
        var page = doc.Pages[pageIndex];
        int delta = clockwise ? 90 : -90;
        page.Rotate = (((page.Rotate + delta) % 360) + 360) % 360;
        doc.Save(outPath);
    }

    public static void Delete(string srcPath, int pageIndex, string outPath)
    {
        using var doc = PdfReader.Open(srcPath, PdfDocumentOpenMode.Modify);
        if (pageIndex < 0 || pageIndex >= doc.PageCount) return;
        doc.Pages.RemoveAt(pageIndex);
        doc.Save(outPath);
    }

    public static void Move(string srcPath, int fromIndex, int toIndex, string outPath)
    {
        using var src = PdfReader.Open(srcPath, PdfDocumentOpenMode.Import);
        var order = Enumerable.Range(0, src.PageCount).ToList();
        if (fromIndex < 0 || fromIndex >= order.Count || toIndex < 0 || toIndex >= order.Count) return;
        var item = order[fromIndex];
        order.RemoveAt(fromIndex);
        order.Insert(toIndex, item);

        using var outDoc = new PdfDocument();
        foreach (var idx in order)
            outDoc.AddPage(src.Pages[idx]);
        outDoc.Save(outPath);
    }

    public static int Append(string srcPath, IEnumerable<string> appendPaths, string outPath)
    {
        using var outDoc = new PdfDocument();
        using (var src = PdfReader.Open(srcPath, PdfDocumentOpenMode.Import))
            for (int i = 0; i < src.PageCount; i++)
                outDoc.AddPage(src.Pages[i]);

        int added = 0;
        foreach (var path in appendPaths)
        {
            using var other = PdfReader.Open(path, PdfDocumentOpenMode.Import);
            for (int i = 0; i < other.PageCount; i++)
            {
                outDoc.AddPage(other.Pages[i]);
                added++;
            }
        }
        outDoc.Save(outPath);
        return added;
    }

    public static void Combine(IEnumerable<string> paths, string outPath)
    {
        using var outDoc = new PdfDocument();
        foreach (var path in paths)
        {
            using var src = PdfReader.Open(path, PdfDocumentOpenMode.Import);
            for (int i = 0; i < src.PageCount; i++)
                outDoc.AddPage(src.Pages[i]);
        }
        outDoc.Save(outPath);
    }

    /// <summary>Extract an inclusive 1-based page range to a new PDF.</summary>
    public static void Extract(string srcPath, int start1, int end1, string outPath)
    {
        using var src = PdfReader.Open(srcPath, PdfDocumentOpenMode.Import);
        using var outDoc = new PdfDocument();
        for (int i = start1; i <= end1 && i <= src.PageCount; i++)
        {
            if (i >= 1) outDoc.AddPage(src.Pages[i - 1]);
        }
        outDoc.Save(outPath);
    }

    /// <summary>Parse "3-10" or "5" into an inclusive 1-based range, validated against totalPages.</summary>
    public static (int Start, int End)? ParseRange(string input, int totalPages)
    {
        var trimmed = input.Trim();
        if (trimmed.Contains('-'))
        {
            var parts = trimmed.Split('-', 2);
            if (int.TryParse(parts[0].Trim(), out int a) && int.TryParse(parts[1].Trim(), out int b)
                && a >= 1 && b >= a && b <= totalPages)
                return (a, b);
            return null;
        }
        if (int.TryParse(trimmed, out int single) && single >= 1 && single <= totalPages)
            return (single, single);
        return null;
    }
}
