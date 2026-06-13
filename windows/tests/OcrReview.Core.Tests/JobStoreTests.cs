using OcrReview.Core.Models;
using OcrReview.Core.Services;
using Xunit;

namespace OcrReview.Core.Tests;

public class JobStoreTests : IDisposable
{
    private readonly string _tmp = Path.Combine(Path.GetTempPath(), "ocrreview-test-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void Save_and_load_roundtrip_preserves_redaction()
    {
        var store = new JobStore(_tmp);
        var doc = new OcrDocument { Filename = "r.pdf", TotalPageCount = 1 };
        doc.Pages.Add(new OcrPage
        {
            PageNumber = 1,
            OcrText = "hi",
            Blocks = { new OcrBlock { Text = "hi", Confidence = 0.9f, IsRedacted = true } },
        });
        store.Save(doc);

        var loaded = store.Load(doc.Id);
        Assert.NotNull(loaded);
        Assert.Equal("r.pdf", loaded!.Filename);
        Assert.True(loaded.Pages[0].Blocks[0].IsRedacted);
    }

    [Fact]
    public void Save_updates_recents_most_recent_first()
    {
        var store = new JobStore(_tmp);
        store.Save(new OcrDocument { Filename = "a.pdf" });
        store.Save(new OcrDocument { Filename = "b.pdf" });

        var recents = store.Recents;
        Assert.Equal(2, recents.Count);
        Assert.Equal("b.pdf", recents[0].Filename);
    }

    [Fact]
    public void Recents_survive_a_reopen()
    {
        var doc = new OcrDocument { Filename = "persist.pdf" };
        new JobStore(_tmp).Save(doc);

        var reopened = new JobStore(_tmp);
        Assert.Contains(reopened.Recents, d => d.Filename == "persist.pdf");
    }

    public void Dispose()
    {
        try { Directory.Delete(_tmp, recursive: true); } catch { /* ignore */ }
    }
}
