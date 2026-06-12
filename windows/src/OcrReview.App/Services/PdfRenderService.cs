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
            // Load into locals and swap only on success — clearing the current
            // document first would leave the whole app rendering blank if the new
            // file turns out to be corrupt or password-protected.
            PdfDocument? pdf = null;
            string? imagePath = null;
            if (DocumentLoader.IsPdf(path))
            {
                var file = await StorageFile.GetFileFromPathAsync(path);
                pdf = await PdfDocument.LoadFromFileAsync(file);
            }
            else
            {
                imagePath = path;
            }
            _pdf = pdf;
            _imagePath = imagePath;
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
            if (_imagePath == null) return null;
            // Decode through the SAME WinRT path as OCR (EXIF rotation applied), so a
            // phone photo displays upright and the OCR bounding boxes line up with what
            // the user sees. WPF's BitmapImage ignores EXIF and would mismatch.
            var sb = await DecodeImageAsync(_imagePath);
            if (sb == null) return LoadImageFile(_imagePath);
            using var ras = new InMemoryRandomAccessStream();
            var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(
                Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, ras);
            encoder.SetSoftwareBitmap(sb);
            await encoder.FlushAsync();
            ras.Seek(0);
            return ToBitmap(ras);
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
        if (_pdf != null)
        {
            if (index < 0 || index >= (int)_pdf.PageCount) return null;
            using var page = _pdf.GetPage((uint)index);
            using var mem = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(mem, new PdfPageRenderOptions { DestinationWidth = (uint)Math.Max(pixelWidth, 1) });
            mem.Seek(0);
            var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(mem);
            return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        }
        return _imagePath != null ? await DecodeImageAsync(_imagePath) : null;
    }

    /// <summary>OCR engine dimension cap (OcrEngine.MaxImageDimension is typically
    /// larger, but huge scans waste memory and 16-bit/odd formats throw). Images decode
    /// to Bgra8 with EXIF rotation applied and are downscaled past this size.</summary>
    private const uint MaxImageDimension = 7500;

    private static async Task<SoftwareBitmap?> DecodeImageAsync(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        using var stream = await file.OpenAsync(FileAccessMode.Read);
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);

        // OrientedPixelWidth/Height account for the EXIF rotation we're about to apply.
        uint w = decoder.OrientedPixelWidth, h = decoder.OrientedPixelHeight;
        var transform = new BitmapTransform();
        if (w > MaxImageDimension || h > MaxImageDimension)
        {
            double scale = Math.Min((double)MaxImageDimension / w, (double)MaxImageDimension / h);
            transform.ScaledWidth = (uint)Math.Max(w * scale, 1);
            transform.ScaledHeight = (uint)Math.Max(h * scale, 1);
        }

        // Bgra8 + EXIF rotation: Windows OCR rejects some native formats outright
        // ("unspecified error"), and un-rotated phone photos OCR sideways.
        return await decoder.GetSoftwareBitmapAsync(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied,
            transform,
            ExifOrientationMode.RespectExifOrientation,
            ColorManagementMode.DoNotColorManage);
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
