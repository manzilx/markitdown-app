using OcrReview.Core.Models;
using OcrReview.Core.Services;
using Xunit;

namespace OcrReview.Core.Tests;

public class DenoiseServiceTests
{
    // Distinct word pairs per line so body lines have unique normalized keys
    // (i.e. they are NOT mistaken for repeated headers/footers).
    private static readonly string[] Pool =
    {
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
        "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
        "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray",
    };

    private static List<string> UniqueBody(int page, int lines)
    {
        var result = new List<string>();
        for (int k = 0; k < lines; k++)
        {
            var a = Pool[(page * 7 + k * 3) % Pool.Length];
            var b = Pool[(page * 11 + k * 5) % Pool.Length];
            result.Add($"The {a} section reviews {b} findings in depth.");
        }
        return result;
    }

    private static string Page(int n, string? header, string? footer, int bodyLines = 8)
    {
        var lines = new List<string>();
        if (header != null) lines.Add(header);
        lines.AddRange(UniqueBody(n, bodyLines));
        if (footer != null) lines.Add(footer);
        return string.Join("\n", lines);
    }

    private static OcrDocument Doc(IReadOnlyList<string> pageTexts)
    {
        var doc = new OcrDocument { TotalPageCount = pageTexts.Count };
        for (int i = 0; i < pageTexts.Count; i++)
            doc.Pages.Add(new OcrPage { PageNumber = i + 1, OcrText = pageTexts[i] });
        return doc;
    }

    [Fact]
    public void Removes_repeated_header()
    {
        var texts = Enumerable.Range(1, 15).Select(n => Page(n, "ACME ANNUAL REPORT", null)).ToList();
        var result = DenoiseService.Apply(Doc(texts));
        Assert.True(result.Plan.RemovedLineCount > 0);
        foreach (var p in result.Document.Pages)
        {
            Assert.DoesNotContain("ACME ANNUAL REPORT", p.DisplayText);
            Assert.Contains("section reviews", p.DisplayText);
        }
    }

    [Fact]
    public void Removes_page_numbers_offset_from_index()
    {
        // Printed 5..16, file index 1..12 — the case that file-index coupling missed.
        var texts = Enumerable.Range(1, 12).Select(n => Page(n, null, $"{n + 4}")).ToList();
        var result = DenoiseService.Apply(Doc(texts));
        Assert.True(result.Plan.RemovedLineCount >= 12);
        foreach (var p in result.Document.Pages)
        {
            var last = p.DisplayText.Split('\n').LastOrDefault()?.Trim() ?? "";
            Assert.NotEqual($"{p.PageNumber + 4}", last);
        }
    }

    [Fact]
    public void Removes_page_x_of_y_footer()
    {
        var texts = Enumerable.Range(1, 9).Select(n => Page(n, "WEEKLY DIGEST", $"Page {n} of 9")).ToList();
        var result = DenoiseService.Apply(Doc(texts));
        foreach (var p in result.Document.Pages)
        {
            Assert.DoesNotContain("of 9", p.DisplayText.ToLowerInvariant());
            Assert.DoesNotContain("WEEKLY DIGEST", p.DisplayText);
        }
    }

    [Fact]
    public void Removes_roman_numeral_page_numbers()
    {
        var romans = new[] { "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii" };
        var texts = Enumerable.Range(1, 12).Select(n => Page(n, null, romans[n - 1])).ToList();
        var result = DenoiseService.Apply(Doc(texts));
        Assert.True(result.Plan.RemovedLineCount >= 12);
        foreach (var p in result.Document.Pages)
        {
            var last = p.DisplayText.Split('\n').LastOrDefault()?.Trim() ?? "";
            Assert.NotEqual(romans[p.PageNumber - 1], last);
        }
    }

    [Fact]
    public void Roman_lookalike_words_are_not_page_numbers()
    {
        var words = new[] { "mild", "dim", "civil", "livid", "mild", "dim", "civil", "livid", "mild", "dim" };
        var texts = new List<string>();
        for (int n = 1; n <= 10; n++)
        {
            var lines = UniqueBody(n, 8);
            lines.Add($"{words[n - 1]} {Pool[n % Pool.Length]}");
            texts.Add(string.Join("\n", lines));
        }
        var result = DenoiseService.Apply(Doc(texts));
        Assert.Equal(0, result.Plan.RemovedLineCount);
    }

    [Fact]
    public void Selective_apply_respects_enabled_keys()
    {
        var texts = Enumerable.Range(1, 12).Select(n => Page(n, "ACME ANNUAL REPORT", $"Page {n}")).ToList();
        var doc = Doc(texts);
        var plan = DenoiseService.MakePlan(doc);
        Assert.Equal(2, plan.Candidates.Count);

        // Only page numbers enabled → header kept.
        var onlyNumbers = DenoiseService.Apply(plan, Doc(texts), new HashSet<string> { DenoiseService.PageNumberKey });
        foreach (var p in onlyNumbers.Document.Pages)
        {
            Assert.Contains("ACME ANNUAL REPORT", p.DisplayText);
            Assert.DoesNotContain($"page {p.PageNumber}", p.DisplayText.ToLowerInvariant());
        }

        // Only header enabled → page numbers kept.
        var headerKey = plan.Candidates.First(c => c.Reason == DenoiseService.Reason.RepeatedEdgeText).Key;
        var onlyHeader = DenoiseService.Apply(plan, Doc(texts), new HashSet<string> { headerKey });
        foreach (var p in onlyHeader.Document.Pages)
        {
            Assert.DoesNotContain("ACME ANNUAL REPORT", p.DisplayText);
            Assert.Contains($"page {p.PageNumber}", p.DisplayText.ToLowerInvariant());
        }
    }

    [Fact]
    public void Removes_date_stamped_footer_with_varying_months()
    {
        // Same footer template but the month NAME varies — digits alone can't cluster these.
        var months = new[] { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October" };
        var texts = Enumerable.Range(1, 10)
            .Select(n => Page(n, null, $"Printed on {n + 3} {months[n - 1]} 2024 at 14:0{n % 10}"))
            .ToList();
        var result = DenoiseService.Apply(Doc(texts));
        Assert.True(result.Plan.RemovedLineCount >= 10);
        foreach (var p in result.Document.Pages)
        {
            Assert.DoesNotContain("Printed on", p.DisplayText);
            Assert.Contains("section reviews", p.DisplayText);
        }
    }

    [Fact]
    public void Removes_midpage_watermark_stamp()
    {
        // A stamp OCR'd into the middle of the page is outside the edge zones.
        var texts = new List<string>();
        for (int n = 1; n <= 10; n++)
        {
            var lines = UniqueBody(n, 4);
            lines.Add("*** CONFIDENTIAL ***");
            lines.AddRange(UniqueBody(n + 100, 4));
            // Body sentence CONTAINING a stamp word must survive (not a whole-line match).
            lines.Add($"Please copy the {Pool[n % Pool.Length]} ledger today.");
            lines.AddRange(UniqueBody(n + 200, 3));
            texts.Add(string.Join("\n", lines));
        }
        var result = DenoiseService.Apply(Doc(texts));
        Assert.True(result.Plan.RemovedLineCount >= 10);
        Assert.Contains(result.Plan.Candidates, c => c.Reason == DenoiseService.Reason.Watermark);
        foreach (var p in result.Document.Pages)
        {
            Assert.DoesNotContain("CONFIDENTIAL", p.DisplayText);
            Assert.Contains("Please copy the", p.DisplayText);
        }
    }

    [Fact]
    public void Lone_watermark_word_on_one_page_of_many_is_kept()
    {
        // "DRAFT" on a single page of a 10-page doc doesn't recur — leave it.
        var texts = Enumerable.Range(1, 10).Select(n => Page(n, null, null)).ToList();
        texts[4] = "DRAFT\n" + texts[4];
        var result = DenoiseService.Apply(Doc(texts));
        Assert.Equal(0, result.Plan.RemovedLineCount);
    }

    [Fact]
    public void Never_empties_a_page()
    {
        var texts = Enumerable.Range(1, 10).Select(n => $"REPEATED HEADER\n{n}").ToList();
        var result = DenoiseService.Apply(Doc(texts));
        foreach (var p in result.Document.Pages)
            Assert.False(string.IsNullOrWhiteSpace(p.DisplayText), $"page {p.PageNumber} emptied");
    }

    [Fact]
    public void Noop_on_clean_document()
    {
        var texts = Enumerable.Range(1, 8).Select(n => Page(n, null, null)).ToList();
        var result = DenoiseService.Apply(Doc(texts));
        Assert.Equal(0, result.Plan.RemovedLineCount);
    }

    [Fact]
    public void Empty_document_produces_empty_plan()
    {
        var result = DenoiseService.Apply(Doc(new List<string>()));
        Assert.Equal(0, result.Plan.RemovedLineCount);
    }
}
