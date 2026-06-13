using System.Reflection;
using System.Text.RegularExpressions;
using OcrReview.Core.Abstractions;
using OcrReview.Core.Models;
using WeCantSpell.Hunspell;

namespace OcrReview.Core.Services;

/// <summary>
/// Dictionary-backed spell checker (en-US Hunspell, embedded in this assembly).
/// Drives "suspect" detection and one-click fixes — important on Windows where the
/// OCR engine provides no confidence scores.
/// </summary>
public sealed class HunspellSpellChecker : ISpellChecker
{
    private static readonly Lazy<WordList?> Words = new(LoadWordList);
    private static readonly Regex WordRx = new(@"[\p{L}][\p{L}'’]*", RegexOptions.Compiled);

    public bool IsAvailable => Words.Value != null;

    public IReadOnlyList<SpellIssue> Issues(string text)
    {
        var results = new List<SpellIssue>();
        var words = Words.Value;
        if (words == null || string.IsNullOrWhiteSpace(text)) return results;

        foreach (Match m in WordRx.Matches(text))
        {
            var token = m.Value;
            if (ShouldSkip(token)) continue;
            if (words.Check(token)) continue;

            var suggestions = words.Suggest(token).Take(5).ToList();
            if (suggestions.Count == 0) continue;

            results.Add(new SpellIssue
            {
                Word = token,
                Location = m.Index,
                Length = m.Length,
                Suggestions = suggestions,
            });
        }
        return results;
    }

    public string Replace(string text, SpellIssue issue, string replacement)
    {
        if (issue.Location < 0 || issue.Location + issue.Length > text.Length) return text;
        return string.Concat(text.AsSpan(0, issue.Location), replacement, text.AsSpan(issue.Location + issue.Length));
    }

    private static bool ShouldSkip(string word)
    {
        if (word.Length <= 1) return true;
        if (word.Any(char.IsDigit)) return true;
        return false;
    }

    private static WordList? LoadWordList()
    {
        try
        {
            var asm = typeof(HunspellSpellChecker).Assembly;
            using var dic = FindResource(asm, "en_US.dic");
            using var aff = FindResource(asm, "en_US.aff");
            if (dic == null || aff == null) return null;
            return WordList.CreateFromStreams(dic, aff);
        }
        catch
        {
            return null;
        }
    }

    private static Stream? FindResource(Assembly asm, string endsWith)
    {
        var name = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(endsWith, StringComparison.OrdinalIgnoreCase));
        return name == null ? null : asm.GetManifestResourceStream(name);
    }
}
