using System.IO;
using System.Windows.Media.Imaging;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace OcrReview.App.Services;

/// <summary>
/// Renders PDF pages (via Windows.Data.Pdf) and images for display and OCR.
/// All render calls are serialized — Windows.Data.Pdf is not thread-safe.
/// Read-only; structural edits go through <see cref="PdfEditService"/>.
/// </summary>
public sealed class PdfRenderService
{
    private readonly SemaphoreSlim _lock = new(1, 1);
    private PdfDocument? _pdf;
    private string? _imagePath;

    public bool HasDocument => _pdf != null || _imagePath != null;
    public bool IsPdf => _pdf != null;
    public int PageCount => _pdf != null ? (int)_pdf.PageCount : (_imagePath != null ? 1 : 0);

    public async Task LoadAsync(string path)
    {
        await _lock.WaitAsync();
        try
        {
            _pdf = null;
            _imagePath = null;
            if (DocumentLoader.IsPdf(path))
            {
                var file = await StorageFile.GetFileFromPathAsync(path);
                _pdf = await PdfDocument.LoadFromFileAsync(file);
            }
            else
            {
                _imagePath = path;
            }
        }
        finally { _lock.Release(); }
    }

    public async Task<BitmapSource?> RenderPageAsync(int index, double pixelWidth)
    {
        await _lock.WaitAsync();
        try
        {
            if (_pdf != null)
            {
                if (index < 0 || index >= (int)_pdf.PageCount) return null;
                using var page = _pdf.GetPage((uint)index);
                using var stream = new InMemoryRandomAccessStream();
                await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = (uint)Math.Max(pixelWidth, 1) });
                stream.Seek(0);
                return ToBitmap(stream);
            }
            return _imagePath != null ? LoadImageFile(_imagePath) : null;
        }
        finally { _lock.Release(); }
    }

    public async Task<SoftwareBitmap?> RenderPageSoftwareBitmapAsync(int index, double pixelWidth = 2200)
    {
        await _lock.WaitAsync();
        try { return await RenderSoftwareBitmapCoreAsync(index, pixelWidth); }
        finally { _lock.Release(); }
    }

    public async Task<byte[]?> RenderPagePngAsync(int index, double pixelWidth = 2200)
    {
        await _lock.WaitAsync();
        try
        {
            if (_pdf == null && _imagePath != null)
                return await File.ReadAllBytesAsync(_imagePath);

            var bitmap = await RenderSoftwareBitmapCoreAsync(index, pixelWidth);
            if (bitmap == null) return null;

            var converted = bitmap.BitmapPixelFormat == BitmapPixelFormat.Bgra8
                ? bitmap
                : SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);

            using var ras = new InMemoryRandomAccessStream();
            var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(
                Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, ras);
            encoder.SetSoftwareBitmap(converted);
            await encoder.FlushAsync();
            ras.Seek(0);
            using var stream = ras.AsStream();
            using var ms = new MemoryStream();
            await stream.CopyToAsync(ms);
            return ms.ToArray();
        }
        finally { _lock.Release(); }
    }

    private async Task<SoftwareBitmap?> RenderSoftwareBitmapCoreAsync(int index, double pixelWidth)
    {
        IRandomAccessStream? stream = null;
        try
        {
            if (_pdf != null)
            {
                if (index < 0 || index >= (int)_pdf.PageCount) return null;
                using var page = _pdf.GetPage((uint)index);
                var mem = new InMemoryRandomAccessStream();
                await page.RenderToStreamAsync(mem, new PdfPageRenderOptions { DestinationWidth = (uint)Math.Max(pixelWidth, 1) });
                mem.Seek(0);
                stream = mem;
            }
            else if (_imagePath != null)
            {
                var file = await StorageFile.GetFileFromPathAsync(_imagePath);
                stream = await file.OpenAsync(FileAccessMode.Read);
            }
            else
            {
                return null;
            }

            var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
            return await decoder.GetSoftwareBitmapAsync();
        }
        finally
        {
            stream?.Dispose();
        }
    }

    private static BitmapSource ToBitmap(IRandomAccessStream ras)
    {
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.StreamSource = ras.AsStream();
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }

    private static BitmapSource LoadImageFile(string path)
    {
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.UriSource = new Uri(path);
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }
}
