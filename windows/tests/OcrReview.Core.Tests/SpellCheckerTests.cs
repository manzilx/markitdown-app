using OcrReview.Core.Services;
using Xunit;

namespace OcrReview.Core.Tests;

public class SpellCheckerTests
{
    private readonly HunspellSpellChecker _spell = new();

    [Fact]
    public void Dictionary_loads()
    {
        Assert.True(_spell.IsAvailable);
    }

    [Fact]
    public void Correct_text_has_no_issues()
    {
        Assert.Empty(_spell.Issues("The quick brown fox jumps over the lazy dog."));
    }

    [Fact]
    public void Misspelling_is_flagged_with_suggestions()
    {
        var issues = _spell.Issues("teh quick fox");
        var issue = Assert.Single(issues);
        Assert.Equal("teh", issue.Word);
        Assert.Contains("the", issue.Suggestions);
    }

    [Fact]
    public void Replace_swaps_the_flagged_word()
    {
        const string text = "teh quick fox";
        var issue = _spell.Issues(text)[0];
        Assert.Equal("the quick fox", _spell.Replace(text, issue, "the"));
    }

    [Fact]
    public void Tokens_with_digits_are_skipped()
    {
        Assert.Empty(_spell.Issues("Item A1B2 code"));
    }
}
