using OcrReview.Core;
using OcrReview.Core.Abstractions;
using OcrReview.Core.Models;
using OcrReview.Core.Services;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace OcrReview.App.Services;

/// <summary>
/// On-device OCR using Windows.Media.Ocr. The engine reports no per-word confidence,
/// so we derive a "suspect" confidence from the spell checker — that drives the
/// heatmap, suspect spans, and jump-to-issue review just like the macOS app.
/// </summary>
public sealed class WindowsOcrService
{
    // Lazy + guarded: WinRT activation must NOT run at app startup (it can fail to load
    // in a packaged/self-contained build and would crash the window before it appears).
    // Creation retries on every call while null, so installing an OCR language pack
    // mid-session starts working without an app restart.
    private OcrEngine? _engine;
    private readonly object _engineGate = new();

    /// <summary>OcrEngine does not support concurrent RecognizeAsync on one instance —
    /// a background prefetch overlapping a user-triggered recognize fails with a WinRT
    /// "method called at an unexpected time" error. Serialize all recognition.</summary>
    private readonly SemaphoreSlim _recognizeGate = new(1, 1);
    private readonly ISpellChecker _spell;

    public WindowsOcrService(ISpellChecker spell) => _spell = spell;

    public bool IsAvailable => GetEngine() != null;

    private OcrEngine? GetEngine()
    {
        lock (_engineGate)
        {
            if (_engine != null) return _engine;
            try { _engine = OcrEngine.TryCreateFromUserProfileLanguages(); }
            catch { _engine = null; }
            return _engine;
        }
    }

    public async Task<OcrPage> RecognizeAsync(SoftwareBitmap bitmap, int pageNumber)
    {
        var engine = GetEngine()
            ?? throw new InvalidOperationException(
                "Windows OCR is unavailable. Add an OCR language in Windows Settings → Time & language → Language & region.");

        OcrResult result;
        await _recognizeGate.WaitAsync();
        try
        {
            result = await engine.RecognizeAsync(bitmap);
        }
        finally
        {
            _recognizeGate.Release();
        }
        int width = bitmap.PixelWidth;
        int height = bitmap.PixelHeight;

        // First pass: measure each engine line. The engine's line order is not reading
        // order (same-row fragments and columns come back scrambled), so sort before emitting.
        var measured = new List<(string Text, double MinX, double MinY, double MaxX, double MaxY, bool HasBox)>();
        foreach (var line in result.Lines)
        {
            double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
            bool any = false;
            foreach (var word in line.Words)
            {
                var r = word.BoundingRect;
                any = true;
                minX = Math.Min(minX, r.X);
                minY = Math.Min(minY, r.Y);
                maxX = Math.Max(maxX, r.X + r.Width);
                maxY = Math.Max(maxY, r.Y + r.Height);
            }
            measured.Add((line.Text, minX, minY, maxX, maxY, any));
        }

        var boxed = measured.Where(m => m.HasBox).ToList();
        var ordered = ReadingOrderService
            .Order(boxed.Select(m => (m.MinX, m.MinY, m.MaxX - m.MinX, m.MaxY - m.MinY)).ToList())
            .Select(i => boxed[i])
            .Concat(measured.Where(m => !m.HasBox))
            .ToList();

        var blocks = new List<OcrBlock>();
        var lines = new List<string>();

        foreach (var m in ordered)
        {
            double[]? bbox = null;
            if (m.HasBox && width > 0 && height > 0)
            {
                double nx = m.MinX / width;
                double nw = (m.MaxX - m.MinX) / width;
                double nh = (m.MaxY - m.MinY) / height;
                double nyBottomLeft = 1.0 - (m.MaxY / height); // convert top-left pixel origin → bottom-left normalized
                bbox = new[] { nx, nyBottomLeft, nw, nh };
            }

            var issues = _spell.Issues(m.Text);
            float confidence = issues.Count > 0 ? OcrConstants.SuspectConfidence : 1f;

            blocks.Add(new OcrBlock { Text = m.Text, Confidence = confidence, BboxNormalized = bbox });
            lines.Add(m.Text);
        }

        return new OcrPage
        {
            PageNumber = pageNumber,
            OcrText = string.Join("\n", lines),
            Blocks = blocks,
        };
    }
}
