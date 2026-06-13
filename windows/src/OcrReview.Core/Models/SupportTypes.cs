using System.Text.Json.Serialization;

namespace OcrReview.Core.Models;

public sealed class SpellIssue
{
    public string Word { get; init; } = "";
    public int Location { get; init; }
    public int Length { get; init; }
    public IReadOnlyList<string> Suggestions { get; init; } = Array.Empty<string>();
}

public sealed class FindMatch
{
    public int PageNumber { get; init; }
    public int Start { get; init; }
    public int Length { get; init; }
    public string Snippet { get; init; } = "";
}

public sealed class SidecarEngineInfo
{
    public string Id { get; init; } = "";
    public string Label { get; init; } = "";
    public string Description { get; init; } = "";
    public string Badge { get; init; } = "";
    public bool Available { get; init; }
    public string? Reason { get; init; }
}

public sealed class EnginesResponse
{
    [JsonPropertyName("engines")] public List<SidecarEngineInfo> Engines { get; init; } = new();
    [JsonPropertyName("default_engine")] public string DefaultEngine { get; init; } = "builtin";
}
