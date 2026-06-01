using System.Windows.Media.Imaging;

namespace OcrReview.App.Services;

/// <summary>Caches rendered page thumbnails so the strip doesn't re-render on every redraw.</summary>
public sealed class ThumbnailCache
{
    private readonly Dictionary<string, BitmapSource> _cache = new();

    public BitmapSource? Get(string key) => _cache.TryGetValue(key, out var value) ? value : null;

    public void Set(string key, BitmapSource image) => _cache[key] = image;

    public void Clear() => _cache.Clear();
}
