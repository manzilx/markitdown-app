using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using OcrReview.App.Services;
using OcrReview.App.ViewModels;
using OcrReview.Core;

namespace OcrReview.App.Views;

public partial class PdfPageView : UserControl
{
    private DocumentViewModel? _vm;
    private readonly List<(Guid Id, Rect Rect)> _hitRects = new();

    private static readonly Brush AccentBrush = Frozen(Color.FromRgb(0x72, 0x70, 0xF5));
    private static readonly Brush BlackBrush = Frozen(Colors.Black);

    public PdfPageView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (_vm != null) _vm.PropertyChanged -= OnVmChanged;
        _vm = DataContext as DocumentViewModel;
        if (_vm != null) _vm.PropertyChanged += OnVmChanged;
        ScheduleRedraw();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(DocumentViewModel.CurrentPageImage)
            or nameof(DocumentViewModel.OverlayVersion)
            or nameof(DocumentViewModel.CurrentBlocks))
        {
            ScheduleRedraw();
        }
    }

    private void OnImageSizeChanged(object sender, SizeChangedEventArgs e) => ScheduleRedraw();

    private void ScheduleRedraw() =>
        Dispatcher.BeginInvoke(Redraw, System.Windows.Threading.DispatcherPriority.Loaded);

    private void Redraw()
    {
        Overlay.Children.Clear();
        _hitRects.Clear();

        if (_vm?.CurrentPageImage is not BitmapSource src) return;
        double pixelW = src.PixelWidth, pixelH = src.PixelHeight;
        double ctrlW = PageImage.ActualWidth, ctrlH = PageImage.ActualHeight;
        if (pixelW <= 0 || pixelH <= 0 || ctrlW <= 0 || ctrlH <= 0) return;

        double scale = Math.Min(ctrlW / pixelW, ctrlH / pixelH);
        double dispW = pixelW * scale, dispH = pixelH * scale;
        double offsetX = (ctrlW - dispW) / 2, offsetY = (ctrlH - dispH) / 2;

        var selected = _vm.SelectedBlockId;
        var redacted = _vm.CurrentRedactedBlockIds;
        bool heatmap = _vm.ShowHeatmap;

        foreach (var block in _vm.CurrentBlocks)
        {
            if (block.BboxNormalized is not { Length: 4 } bbox) continue;
            var r = BboxMapper.ViewRect(bbox, dispW, dispH);
            var rect = new Rect(r.X + offsetX, r.Y + offsetY, r.Width, r.Height);
            _hitRects.Add((block.Id, rect));

            bool isSelected = block.Id == selected;
            bool isRedacted = redacted.Contains(block.Id);

            var shape = new Rectangle
            {
                Width = Math.Max(rect.Width, 1),
                Height = Math.Max(rect.Height, 1),
                RadiusX = 3,
                RadiusY = 3,
                IsHitTestVisible = false,
            };

            if (isRedacted)
            {
                shape.Fill = BlackBrush;
                shape.Stroke = BlackBrush;
                shape.StrokeThickness = 1;
            }
            else
            {
                Color baseColor = isSelected ? Color.FromRgb(0x72, 0x70, 0xF5)
                    : heatmap ? ConfidenceColor(block.Confidence)
                    : Color.FromRgb(0x72, 0x70, 0xF5);
                shape.Fill = new SolidColorBrush(WithAlpha(baseColor, isSelected ? 0.26 : heatmap ? 0.20 : 0.10));
                shape.Stroke = new SolidColorBrush(WithAlpha(baseColor, isSelected ? 1.0 : 0.7));
                shape.StrokeThickness = isSelected ? 2 : 1;
            }

            Canvas.SetLeft(shape, rect.X);
            Canvas.SetTop(shape, rect.Y);
            Overlay.Children.Add(shape);
        }
    }

    private void OnOverlayClick(object sender, MouseButtonEventArgs e)
    {
        if (_vm == null) return;
        var p = e.GetPosition(Overlay);
        foreach (var (id, rect) in _hitRects)
        {
            if (rect.Contains(p)) { _vm.SelectBlock(id); return; }
        }
        _vm.SelectBlock(null);
    }

    private static Color ConfidenceColor(float confidence) =>
        confidence < 0.6f ? Color.FromRgb(0xF5, 0x6B, 0x6B)
        : confidence < OcrConstants.LowConfidenceThreshold ? Color.FromRgb(0xFB, 0xBC, 0x4D)
        : Color.FromRgb(0x4D, 0xD1, 0x9A);

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B);

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}
