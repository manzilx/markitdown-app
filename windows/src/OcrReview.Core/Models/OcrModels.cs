using System.Text.Json.Serialization;

namespace OcrReview.Core.Models;

/// <summary>A recognized region (line) with optional geometry, mirroring the macOS model.</summary>
public sealed class OcrBlock
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public float Confidence { get; set; } = 1f;

    /// <summary>Normalized bbox [minX, minY, width, height], origin bottom-left (Vision convention).</summary>
    public double[]? BboxNormalized { get; set; }

    /// <summary>Original recognized text, preserved so edits can be reverted.</summary>
    public string? OriginalText { get; set; }

    /// <summary>Blacked out — hidden on the page and removed from exports.</summary>
    public bool IsRedacted { get; set; }

    [JsonIgnore] public string PristineText => OriginalText ?? Text;
    [JsonIgnore] public bool HasEdits => Text != PristineText;
    [JsonIgnore] public bool IsLowConfidence => Confidence < OcrConstants.LowConfidenceThreshold;

    public void RevertToOriginal() => Text = PristineText;
}

public sealed class OcrPage
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public int PageNumber { get; set; }
    public string OcrText { get; set; } = "";
    public string? EditedText { get; set; }
    public List<OcrBlock> Blocks { get; set; } = new();

    [JsonIgnore]
    public string DisplayText => !string.IsNullOrEmpty(EditedText) ? EditedText! : OcrText;

    /// <summary>Text for exports — excludes redacted regions, falling back to DisplayText.</summary>
    [JsonIgnore]
    public string ExportText
    {
        get
        {
            if (!Blocks.Any(b => b.IsRedacted)) return DisplayText;
            var kept = Blocks
                .Where(b => !b.IsRedacted)
                .OrderByDescending(b => b.BboxNormalized is { Length: 4 } box ? box[1] : 0)
                .Select(b => b.Text)
                .Where(t => !string.IsNullOrEmpty(t));
            return string.Join("\n", kept);
        }
    }

    [JsonIgnore] public IEnumerable<OcrBlock> LowConfidenceBlocks => Blocks.Where(b => b.IsLowConfidence);
    [JsonIgnore] public bool HasRedactions => Blocks.Any(b => b.IsRedacted);

    [JsonIgnore]
    public bool HasEdits =>
        (EditedText != null && EditedText != OcrText) || Blocks.Any(b => b.HasEdits);

    /// <summary>Low-confidence blocks ordered top-to-bottom for review navigation.</summary>
    [JsonIgnore]
    public IEnumerable<OcrBlock> IssuesInReadingOrder =>
        LowConfidenceBlocks.OrderByDescending(b => b.BboxNormalized is { Length: 4 } box ? box[1] : 0);

    public void SetDisplayText(string text) => EditedText = text;

    public void SyncEditedTextFromBlocks()
    {
        var sorted = Blocks
            .OrderByDescending(b => b.BboxNormalized is { Length: 4 } box ? box[1] : 0)
            .Select(b => b.Text);
        EditedText = string.Join("\n", sorted);
    }

    public void RevertToOriginal()
    {
        EditedText = null;
        foreach (var block in Blocks) block.RevertToOriginal();
    }
}

public sealed class OcrDocument
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Filename { get; set; } = "";
    public string SourcePath { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public List<OcrPage> Pages { get; set; } = new();
    public string Engine { get; set; } = "windows";

    /// <summary>Total pages in the source (may exceed OCR'd pages).</summary>
    public int TotalPageCount { get; set; }

    public OcrPage? Page(int number) => Pages.FirstOrDefault(p => p.PageNumber == number);

    [JsonIgnore] public int OcrPageCount => Pages.Count;

    [JsonIgnore] public int IssueCount => Pages.Sum(p => p.LowConfidenceBlocks.Count());

    [JsonIgnore]
    public double AverageConfidence
    {
        get
        {
            var blocks = Pages.SelectMany(p => p.Blocks).Where(b => b.BboxNormalized != null).ToList();
            if (blocks.Count == 0) return 1;
            return blocks.Average(b => (double)b.Confidence);
        }
    }
}

public enum LoadedSourceKind
{
    Pdf,
    Image
}

public sealed class LoadedSource
{
    public LoadedSourceKind Kind { get; init; }
    public string Path { get; init; } = "";
    public int PageCount { get; init; } = 1;
}
