using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using OcrReview.App.ViewModels;
using OcrReview.Core.Services;

namespace OcrReview.App.Views;

public partial class SettingsWindow : Window
{
    private static readonly Brush Green = Brushes.MediumSeaGreen;
    private static readonly Brush Red = Brushes.IndianRed;

    private readonly DocumentViewModel _vm;

    public SettingsWindow(DocumentViewModel vm)
    {
        InitializeComponent();
        _vm = vm;
        Loaded += OnLoaded;
        EngineCombo.SelectionChanged += (_, _) => UpdateDescription();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        ProjectRootBox.Text = _vm.Settings.ProjectRoot;
        UrlBox.Text = _vm.Settings.SidecarUrl;

        EngineCombo.Items.Clear();
        EngineCombo.Items.Add(new ComboBoxItem { Content = "Windows OCR (on-device)", Tag = "windows" });
        EngineCombo.SelectedIndex = 0;
        UpdateDescription();

        await RefreshAsync();
    }

    private async System.Threading.Tasks.Task RefreshAsync()
    {
        StatusText.Text = "Checking sidecar…";
        var engines = await _vm.FetchEnginesAsync();

        // Keep the first (Windows OCR) item, replace the rest.
        for (int i = EngineCombo.Items.Count - 1; i >= 1; i--) EngineCombo.Items.RemoveAt(i);
        foreach (var engine in engines)
        {
            var label = string.IsNullOrEmpty(engine.Badge) ? engine.Label : $"{engine.Label} · {engine.Badge}";
            EngineCombo.Items.Add(new ComboBoxItem { Content = label, Tag = engine.Id, IsEnabled = engine.Available });
        }

        // Reselect the saved engine.
        foreach (var obj in EngineCombo.Items)
            if (obj is ComboBoxItem item && (item.Tag as string) == _vm.Settings.Engine)
            {
                EngineCombo.SelectedItem = item;
                break;
            }
        UpdateDescription();

        bool healthy = await _vm.Sidecar.IsAvailableAsync();
        StatusDot.Fill = healthy ? Green : Red;
        StatusText.Text = _vm.SidecarManager.StatusMessage;
    }

    private void UpdateDescription()
    {
        var id = (EngineCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "windows";
        EngineDescription.Text = EngineCatalog.Description(id);
    }

    private async void OnRestart(object sender, RoutedEventArgs e)
    {
        await _vm.SidecarManager.RestartAsync();
        await RefreshAsync();
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await RefreshAsync();

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var id = (EngineCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "windows";
        _vm.ApplySettings(id, UrlBox.Text.Trim(), ProjectRootBox.Text.Trim());
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();
}
