using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using OcrReview.App.ViewModels;

namespace OcrReview.App.Views;

public partial class ThumbnailStrip : UserControl
{
    private static readonly Brush SuccessBrush = Freeze(Color.FromRgb(0x4D, 0xD1, 0x9A));
    private static readonly Brush WarningBrush = Freeze(Color.FromRgb(0xFB, 0xBC, 0x4D));

    private readonly ObservableCollection<ThumbItem> _items = new();
    private DocumentViewModel? _vm;
    private bool _syncingSelection;

    public ThumbnailStrip()
    {
        InitializeComponent();
        List.ItemsSource = _items;
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (_vm != null) _vm.PropertyChanged -= OnVmChanged;
        _vm = DataContext as DocumentViewModel;
        if (_vm != null) _vm.PropertyChanged += OnVmChanged;
        Rebuild();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(DocumentViewModel.TotalPages):
            case nameof(DocumentViewModel.ThumbnailsVersion):
                Rebuild();
                break;
            case nameof(DocumentViewModel.CurrentPageIndex):
                UpdateCurrent();
                break;
            case nameof(DocumentViewModel.OcrPageNumbers):
            case nameof(DocumentViewModel.IssuePageNumbers):
                UpdateStatuses();
                break;
        }
    }

    private void Rebuild()
    {
        if (_vm == null) { _items.Clear(); return; }
        int count = _vm.TotalPages;
        HeaderText.Text = $"PAGES · {count}";

        if (_items.Count != count)
        {
            _items.Clear();
            for (int i = 0; i < count; i++)
                _items.Add(new ThumbItem { Index = i, PageNumber = i + 1 });
        }
        else
        {
            // edit (rotate/reorder/delete): drop cached images so they re-render
            foreach (var item in _items) item.Image = null;
        }
        UpdateStatuses();
        UpdateCurrent();
    }

    private void UpdateStatuses()
    {
        if (_vm == null) return;
        foreach (var item in _items)
        {
            if (_vm.IssuePageNumbers.Contains(item.PageNumber)) item.StatusBrush = WarningBrush;
            else if (_vm.OcrPageNumbers.Contains(item.PageNumber)) item.StatusBrush = SuccessBrush;
            else item.StatusBrush = null;
        }
    }

    private void UpdateCurrent()
    {
        if (_vm == null) return;
        foreach (var item in _items) item.IsCurrent = item.Index == _vm.CurrentPageIndex;

        _syncingSelection = true;
        if (_vm.CurrentPageIndex >= 0 && _vm.CurrentPageIndex < _items.Count)
        {
            List.SelectedIndex = _vm.CurrentPageIndex;
            List.ScrollIntoView(_items[_vm.CurrentPageIndex]);
        }
        _syncingSelection = false;
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection || _vm == null) return;
        if (List.SelectedIndex >= 0) _vm.GoToPage(List.SelectedIndex);
    }

    private async void OnThumbLoaded(object sender, RoutedEventArgs e)
    {
        // async void: a damaged page throws from the renderer, and virtualization
        // re-fires Loaded every time the container scrolls into view — without this
        // guard one bad page means a crash dialog on every scroll. Show a blank thumb.
        try
        {
            if (sender is FrameworkElement { DataContext: ThumbItem item } && item.Image == null && _vm != null)
            {
                var image = await _vm.RenderThumbnailAsync(item.Index);
                if (image != null) item.Image = image;
            }
        }
        catch
        {
            // Leave the placeholder; the page view will surface a real error if the
            // user actually navigates to this page.
        }
    }

    private static Brush Freeze(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}

public sealed class ThumbItem : ObservableObject
{
    public int Index { get; init; }
    public int PageNumber { get; init; }

    private BitmapSource? _image;
    public BitmapSource? Image { get => _image; set => SetProperty(ref _image, value); }

    private bool _isCurrent;
    public bool IsCurrent { get => _isCurrent; set => SetProperty(ref _isCurrent, value); }

    private Brush? _statusBrush;
    public Brush? StatusBrush { get => _statusBrush; set => SetProperty(ref _statusBrush, value); }
}
