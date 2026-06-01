using OcrReview.Core.Models;
using OcrReview.Core.Services;
using Xunit;

namespace OcrReview.Core.Tests;

public class PageStructureServiceTests
{
    private static List<OcrPage> Pages() => new()
    {
        new OcrPage { PageNumber = 1, OcrText = "a" },
        new OcrPage { PageNumber = 2, OcrText = "b" },
        new OcrPage { PageNumber = 3, OcrText = "c" },
    };

    [Fact]
    public void RemapAfterDelete_removes_and_shifts()
    {
        var result = PageStructureService.RemapAfterDelete(Pages(), 2);
        Assert.Equal(2, result.Count);
        Assert.Equal("a", result[0].OcrText);
        Assert.Equal(1, result[0].PageNumber);
        Assert.Equal("c", result[1].OcrText);
        Assert.Equal(2, result[1].PageNumber);
    }

    [Fact]
    public void RemapAfterMove_moves_first_to_last()
    {
        var result = PageStructureService.RemapAfterMove(Pages(), 0, 2, 3);
        Assert.Equal(new[] { "b", "c", "a" }, result.Select(p => p.OcrText).ToArray());
        Assert.Equal(new[] { 1, 2, 3 }, result.Select(p => p.PageNumber).ToArray());
    }

    [Fact]
    public void RemapAfterMove_handles_gaps_when_not_all_pages_ocred()
    {
        var pages = new List<OcrPage> { new() { PageNumber = 1, OcrText = "a" }, new() { PageNumber = 3, OcrText = "c" } };
        var result = PageStructureService.RemapAfterMove(pages, 0, 2, 3);
        // page 1 ("a") moves to slot index 2 → page number 3
        Assert.Equal("a", result.Single(p => p.PageNumber == 3).OcrText);
    }
}
