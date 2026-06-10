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
    // The Rectangle shapes are kept so selection/heatmap/redaction changes recolor them
    // in place instead of clearing and re-allocating the whole overlay every time.
    private readonly List<(Guid Id, Rectangle Shape)> _shapes = new();
    private bool _rebuildPending;
    private bool _restylePending;

    private static readonly Brush AccentFill = Frozen(WithAlpha(Accent, 0.10));
    private static readonly Brush AccentFillSelected = Frozen(WithAlpha(Accent, 0.26));
    private static readonly Brush AccentStroke = Frozen(WithAlpha(Accent, 0.7));
    private static readonly Brush AccentStrokeSelected = Frozen(Accent);
    private static readonly Brush BlackBrush = Frozen(Colors.Black);
    private static readonly Brush HeatHighFill = Frozen(WithAlpha(Color.FromRgb(0x4D, 0xD1, 0x9A), 0.20));
    private static readonly Brush HeatHighStroke = Frozen(WithAlpha(Color.FromRgb(0x4D, 0xD1, 0x9A), 0.7));
    private static readonly Brush HeatMidFill = Frozen(WithAlpha(Color.FromRgb(0xFB, 0xBC, 0x4D), 0.20));
    private static readonly Brush HeatMidStroke = Frozen(WithAlpha(Color.FromRgb(0xFB, 0xBC, 0x4D), 0.7));
    private static readonly Brush HeatLowFill = Frozen(WithAlpha(Color.FromRgb(0xF5, 0x6B, 0x6B), 0.20));
    private static readonly Brush HeatLowStroke = Frozen(WithAlpha(Color.FromRgb(0xF5, 0x6B, 0x6B), 0.7));

    private static Color Accent => Color.FromRgb(0x72, 0x70, 0xF5);

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
        ScheduleRebuild();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(DocumentViewModel.CurrentPageImage):
            case nameof(DocumentViewModel.OverlayVersion):
            case nameof(DocumentViewModel.CurrentBlocks):
                ScheduleRebuild();
                break;
            case nameof(DocumentViewModel.OverlayStyleVersion):
                ScheduleRestyle();
                break;
        }
    }

    private void OnImageSizeChanged(object sender, SizeChangedEventArgs e) => ScheduleRebuild();

    private void ScheduleRebuild()
    {
        if (_rebuildPending) return;
        _rebuildPending = true;
        Dispatcher.BeginInvoke(() => { _rebuildPending = false; Rebuild(); },
            System.Windows.Threading.DispatcherPriority.Render);
    }

    private void ScheduleRestyle()
    {
        if (_restylePending || _rebuildPending) return;
        _restylePending = true;
        Dispatcher.BeginInvoke(() => { _restylePending = false; Restyle(); },
            System.Windows.Threading.DispatcherPriority.Render);
    }

    private void Rebuild()
    {
        Overlay.Children.Clear();
        _hitRects.Clear();
        _shapes.Clear();

        if (_vm?.CurrentPageImage is not BitmapSource src) return;
        double pixelW = src.PixelWidth, pixelH = src.PixelHeight;
        double ctrlW = PageImage.ActualWidth, ctrlH = PageImage.ActualHeight;
        if (pixelW <= 0 || pixelH <= 0 || ctrlW <= 0 || ctrlH <= 0) return;

        double scale = Math.Min(ctrlW / pixelW, ctrlH / pixelH);
        double dispW = pixelW * scale, dispH = pixelH * scale;
        double offsetX = (ctrlW - dispW) / 2, offsetY = (ctrlH - dispH) / 2;

        foreach (var block in _vm.CurrentBlocks)
        {
            if (block.BboxNormalized is not { Length: 4 } bbox) continue;
            var r = BboxMapper.ViewRect(bbox, dispW, dispH);
            var rect = new Rect(r.X + offsetX, r.Y + offsetY, r.Width, r.Height);
            _hitRects.Add((block.Id, rect));

            var shape = new Rectangle
            {
                Width = Math.Max(rect.Width, 1),
                Height = Math.Max(rect.Height, 1),
                RadiusX = 3,
                RadiusY = 3,
                IsHitTestVisible = false,
            };
            Canvas.SetLeft(shape, rect.X);
            Canvas.SetTop(shape, rect.Y);
            Overlay.Children.Add(shape);
            _shapes.Add((block.Id, shape));
        }

        Restyle();
    }

    /// <summary>Recolor existing rectangles for the current selection / heatmap /
    /// redaction state — no allocation, no Canvas teardown.</summary>
    private void Restyle()
    {
        if (_vm == null) return;
        var selected = _vm.SelectedBlockId;
        var redacted = _vm.CurrentRedactedBlockIds;
        bool heatmap = _vm.ShowHeatmap;
        var blocksById = _vm.CurrentBlocks;

        foreach (var (id, shape) in _shapes)
        {
            bool isRedacted = redacted.Contains(id);
            if (isRedacted)
            {
                shape.Fill = BlackBrush;
                shape.Stroke = BlackBrush;
                shape.StrokeThickness = 1;
                continue;
            }

            bool isSelected = id == selected;
            if (isSelected)
            {
                shape.Fill = AccentFillSelected;
                shape.Stroke = AccentStrokeSelected;
                shape.StrokeThickness = 2;
            }
            else if (heatmap)
            {
                float conf = 1f;
                foreach (var b in blocksById)
                    if (b.Id == id) { conf = b.Confidence; break; }
                (shape.Fill, shape.Stroke) = HeatBrushes(conf);
                shape.StrokeThickness = 1;
            }
            else
            {
                shape.Fill = AccentFill;
                shape.Stroke = AccentStroke;
                shape.StrokeThickness = 1;
            }
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

    private static (Brush fill, Brush stroke) HeatBrushes(float confidence) =>
        confidence < 0.6f ? (HeatLowFill, HeatLowStroke)
        : confidence < OcrConstants.LowConfidenceThreshold ? (HeatMidFill, HeatMidStroke)
        : (HeatHighFill, HeatHighStroke);

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B);

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}
