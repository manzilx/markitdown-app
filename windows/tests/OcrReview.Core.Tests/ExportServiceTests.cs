using OcrReview.Core.Models;
using OcrReview.Core.Services;
using Xunit;

namespace OcrReview.Core.Tests;

public class ExportServiceTests
{
    private static OcrDocument SampleDoc()
    {
        var doc = new OcrDocument { Filename = "test.pdf", TotalPageCount = 2 };
        doc.Pages.Add(new OcrPage
        {
            PageNumber = 1,
            OcrText = "Hello world",
            Blocks = { new OcrBlock { Text = "Hello world", Confidence = 0.9f, BboxNormalized = new[] { 0.1, 0.8, 0.4, 0.05 } } },
        });
        doc.Pages.Add(new OcrPage { PageNumber = 2, OcrText = "Second page" });
        return doc;
    }

    [Fact]
    public void Markdown_includes_title_pages_and_text()
    {
        var md = ExportService.Markdown(SampleDoc(), 2);
        Assert.Contains("# test.pdf", md);
        Assert.Contains("## Page 1", md);
        Assert.Contains("Hello world", md);
        Assert.Contains("Second page", md);
    }

    [Fact]
    public void Markdown_notes_partial_ocr()
    {
        var doc = SampleDoc();
        doc.TotalPageCount = 5;
        var md = ExportService.Markdown(doc, 5);
        Assert.Contains("OCR not run on all pages", md);
    }

    [Fact]
    public void PlainText_excludes_redacted_blocks()
    {
        var doc = new OcrDocument { Filename = "t", TotalPageCount = 1 };
        var page = new OcrPage { PageNumber = 1, OcrText = "SECRET\nPUBLIC" };
        page.Blocks.Add(new OcrBlock { Text = "SECRET", BboxNormalized = new[] { 0.1, 0.8, 0.4, 0.05 }, IsRedacted = true });
        page.Blocks.Add(new OcrBlock { Text = "PUBLIC", BboxNormalized = new[] { 0.1, 0.1, 0.4, 0.05 }, IsRedacted = false });
        doc.Pages.Add(page);

        var txt = ExportService.PlainText(doc, 1);
        Assert.Contains("PUBLIC", txt);
        Assert.DoesNotContain("SECRET", txt);
    }

    [Fact]
    public void Rtf_is_well_formed_and_escapes_braces()
    {
        var doc = new OcrDocument { Filename = "a{b}.pdf", TotalPageCount = 1 };
        doc.Pages.Add(new OcrPage { PageNumber = 1, OcrText = "line one" });
        var rtf = ExportService.Rtf(doc, 1);
        Assert.StartsWith(@"{\rtf1", rtf);
        Assert.EndsWith("}", rtf);
        Assert.Contains(@"\{b\}", rtf);
        Assert.Contains("line one", rtf);
    }
}
