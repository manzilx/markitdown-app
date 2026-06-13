using OcrReview.Core.Models;

namespace OcrReview.Core.Abstractions;

/// <summary>On-device OCR. Implemented on Windows with Windows.Media.Ocr.</summary>
public interface IOcrEngine
{
    Task<OcrPage> RecognizeAsync(LoadedSource source, int pageIndex, CancellationToken ct = default);
}

/// <summary>Spell checking used to flag suspect words and offer fixes.</summary>
public interface ISpellChecker
{
    IReadOnlyList<SpellIssue> Issues(string text);
    string Replace(string text, SpellIssue issue, string replacement);
}
