namespace OcrReview.App.ViewModels;

public sealed class PaletteItem
{
    public string Title { get; init; } = "";
    public string Group { get; init; } = "";
    public string Glyph { get; init; } = "";
    public string? Shortcut { get; init; }
    public bool IsEnabled { get; init; } = true;
    public Action Action { get; init; } = () => { };
}
