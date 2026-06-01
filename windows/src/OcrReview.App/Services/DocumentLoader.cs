using System.IO;

namespace OcrReview.App.Services;

public static class DocumentLoader
{
    public static readonly HashSet<string> ImageExtensions =
        new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif" };

    public const string OpenFilter =
        "Documents (*.pdf;*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp)|*.pdf;*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp|" +
        "PDF (*.pdf)|*.pdf|Images (*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp)|*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp|All files (*.*)|*.*";

    public static bool IsPdf(string path) =>
        string.Equals(Path.GetExtension(path), ".pdf", StringComparison.OrdinalIgnoreCase);

    public static bool IsSupported(string path) =>
        IsPdf(path) || ImageExtensions.Contains(Path.GetExtension(path));
}
