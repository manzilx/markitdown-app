using System.Windows;

namespace OcrReview.App.Services;

public static class BboxMapper
{
    /// <summary>
    /// Map a Vision-style normalized bbox [minX, minY, width, height] (origin bottom-left)
    /// onto a rendered content area of the given size (origin top-left, for WPF Canvas).
    /// </summary>
    public static Rect ViewRect(double[] bbox, double contentWidth, double contentHeight)
    {
        double x = bbox[0] * contentWidth;
        double width = bbox[2] * contentWidth;
        double height = bbox[3] * contentHeight;
        double top = (1.0 - bbox[1] - bbox[3]) * contentHeight;
        return new Rect(x, top, Math.Max(width, 0), Math.Max(height, 0));
    }
}
