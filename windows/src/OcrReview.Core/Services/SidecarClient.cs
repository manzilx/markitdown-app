using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using OcrReview.Core.Models;

namespace OcrReview.Core.Services;

public sealed class SidecarException : Exception
{
    public SidecarException(string message) : base(message) { }
}

/// <summary>HTTP client for the Python MarkItDown sidecar (cross-platform).</summary>
public sealed class SidecarClient
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };
    private readonly HttpClient _http;

    public string BaseUrl { get; set; }

    public SidecarClient(string baseUrl)
    {
        BaseUrl = baseUrl.TrimEnd('/');
        // A hung sidecar must not pin IsProcessing forever with no cancel path.
        // 10 minutes comfortably covers huge exports while still bounding the wait.
        _http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
    }

    public async Task<bool> IsAvailableAsync()
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var resp = await _http.GetAsync($"{BaseUrl}/health", cts.Token);
            return resp.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    public async Task<List<SidecarEngineInfo>> FetchEnginesAsync()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var resp = await _http.GetAsync($"{BaseUrl}/v1/engines", cts.Token);
        resp.EnsureSuccessStatusCode();
        var json = await resp.Content.ReadAsStringAsync(cts.Token);
        return JsonSerializer.Deserialize<EnginesResponse>(json, JsonOpts)?.Engines ?? new List<SidecarEngineInfo>();
    }

    public async Task<string> ConvertAsync(byte[] data, string filename, string engine, CancellationToken ct = default)
    {
        using var form = new MultipartFormDataContent();
        var fileContent = new ByteArrayContent(data);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        form.Add(fileContent, "file", filename);
        form.Add(new StringContent(engine), "engine");
        form.Add(new StringContent("false"), "embed_images");

        var resp = await _http.PostAsync($"{BaseUrl}/v1/convert", form, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            throw new SidecarException(ExtractDetail(body) ?? $"OCR failed (HTTP {(int)resp.StatusCode}).");
        return JsonSerializer.Deserialize<ConvertResponse>(body, JsonOpts)?.Markdown ?? "";
    }

    public async Task<byte[]> ExportSearchablePdfAsync(byte[] file, string filename, OcrDocument document, CancellationToken ct = default)
    {
        if (document.OcrPageCount == 0)
            throw new SidecarException("Run OCR on at least one page before exporting.");

        using var form = new MultipartFormDataContent();
        var fileContent = new ByteArrayContent(file);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        form.Add(fileContent, "file", filename);
        form.Add(new StringContent(PagesJson(document)), "pages_json");

        var resp = await _http.PostAsync($"{BaseUrl}/v1/export/searchable-pdf", form, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct);
            throw new SidecarException(ExtractDetail(body) ?? $"Export failed (HTTP {(int)resp.StatusCode}).");
        }
        return await resp.Content.ReadAsByteArrayAsync(ct);
    }

    public async Task<byte[]> ExportDocxAsync(OcrDocument document, string title, CancellationToken ct = default)
    {
        if (document.OcrPageCount == 0)
            throw new SidecarException("Run OCR on at least one page before exporting.");

        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(PagesJson(document)), "pages_json");
        form.Add(new StringContent(title), "title");

        var resp = await _http.PostAsync($"{BaseUrl}/v1/export/docx", form, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct);
            throw new SidecarException(ExtractDetail(body) ?? $"Export failed (HTTP {(int)resp.StatusCode}).");
        }
        return await resp.Content.ReadAsByteArrayAsync(ct);
    }

    /// <summary>Layout-aware Markdown (headings, lists, GFM tables) from the sidecar.
    /// Throws <see cref="SidecarException"/> when unreachable so callers can fall back
    /// to a local dump.</summary>
    public async Task<string> ExportMarkdownAsync(OcrDocument document, string title, CancellationToken ct = default)
    {
        if (document.OcrPageCount == 0)
            throw new SidecarException("Run OCR on at least one page before exporting.");

        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(PagesJson(document)), "pages_json");
        form.Add(new StringContent(title), "title");

        var resp = await _http.PostAsync($"{BaseUrl}/v1/export/markdown", form, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct);
            throw new SidecarException(ExtractDetail(body) ?? $"Export failed (HTTP {(int)resp.StatusCode}).");
        }
        return await resp.Content.ReadAsStringAsync(ct);
    }

    public static string PagesJson(OcrDocument document)
    {
        var pages = document.Pages
            .OrderBy(p => p.PageNumber)
            .Select(p => new ExportPageDto
            {
                PageNumber = p.PageNumber,
                OcrText = p.OcrText,
                EditedText = p.EditedText,
                ExportText = p.ExportText,
                Blocks = p.Blocks.Select(b => new ExportBlockDto
                {
                    Text = b.Text,
                    Confidence = b.Confidence,
                    BboxNormalized = b.BboxNormalized,
                    IsRedacted = b.IsRedacted,
                }).ToList(),
            })
            .ToList();
        return JsonSerializer.Serialize(pages);
    }

    private static string? ExtractDetail(string body)
    {
        try { return JsonSerializer.Deserialize<ErrorDetail>(body, JsonOpts)?.Detail; }
        catch { return null; }
    }

    private sealed class ConvertResponse
    {
        public string Markdown { get; set; } = "";
    }

    private sealed class ErrorDetail
    {
        public string Detail { get; set; } = "";
    }

    private sealed class ExportPageDto
    {
        [JsonPropertyName("page_number")] public int PageNumber { get; set; }
        [JsonPropertyName("ocr_text")] public string OcrText { get; set; } = "";
        [JsonPropertyName("edited_text")] public string? EditedText { get; set; }
        [JsonPropertyName("export_text")] public string ExportText { get; set; } = "";
        [JsonPropertyName("blocks")] public List<ExportBlockDto> Blocks { get; set; } = new();
    }

    private sealed class ExportBlockDto
    {
        [JsonPropertyName("text")] public string Text { get; set; } = "";
        [JsonPropertyName("confidence")] public float Confidence { get; set; }
        [JsonPropertyName("bbox_normalized")] public double[]? BboxNormalized { get; set; }
        [JsonPropertyName("is_redacted")] public bool IsRedacted { get; set; }
    }
}
