using System.ComponentModel;
using System.Windows;
using OcrReview.App.Services;
using OcrReview.App.ViewModels;

namespace OcrReview.App.Views;

public partial class MainWindow : Window
{
    private readonly DocumentViewModel _vm = new();

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _vm;

        Loaded += async (_, _) => await _vm.SidecarManager.EnsureRunningAsync();
        Closing += OnClosing;
        _vm.PropertyChanged += OnViewModelChanged;
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(DocumentViewModel.ErrorMessage) && _vm.ErrorMessage is { } message)
        {
            MessageBox.Show(this, message, "OCR Review", MessageBoxButton.OK, MessageBoxImage.Warning);
            _vm.ErrorMessage = null;
        }
    }

    private void OnClosing(object? sender, CancelEventArgs e) => _vm.FlushSaves();

    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop) &&
            e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files &&
            DocumentLoader.IsSupported(files[0]))
        {
            _ = _vm.OpenAsync(files[0]);
        }
    }
}
