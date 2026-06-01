using OcrReview.Core.Models;
using OcrReview.Core.Services;
using Xunit;

namespace OcrReview.Core.Tests;

public class FindServiceTests
{
    private static OcrDocument Doc(params string[] pageTexts)
    {
        var doc = new OcrDocument { TotalPageCount = pageTexts.Length };
        for (int i = 0; i < pageTexts.Length; i++)
            doc.Pages.Add(new OcrPage { PageNumber = i + 1, OcrText = pageTexts[i] });
        return doc;
    }

    [Fact]
    public void Find_locates_all_matches_across_pages()
    {
        var doc = Doc("the cat sat", "the dog ran the lap");
        var matches = FindService.Find(doc, "the");
        Assert.Equal(3, matches.Count);
        Assert.Equal(1, matches[0].PageNumber);
        Assert.Equal(2, matches[1].PageNumber);
    }

    [Fact]
    public void Find_is_case_insensitive_by_default()
    {
        var doc = Doc("The THE the");
        Assert.Equal(3, FindService.Find(doc, "the").Count);
    }

    [Fact]
    public void Find_empty_query_returns_nothing()
    {
        Assert.Empty(FindService.Find(Doc("anything"), "   "));
    }

    [Fact]
    public void ReplaceAll_replaces_case_insensitively()
    {
        Assert.Equal("x x x", FindService.ReplaceAll("The the THE", "the", "x"));
    }

    [Fact]
    public void ReplaceAt_replaces_single_range()
    {
        Assert.Equal("bye world", FindService.ReplaceAt("hello world", 0, 5, "bye"));
    }

    [Fact]
    public void ReplaceAt_ignores_out_of_range()
    {
        Assert.Equal("hi", FindService.ReplaceAt("hi", 5, 3, "x"));
    }
}
