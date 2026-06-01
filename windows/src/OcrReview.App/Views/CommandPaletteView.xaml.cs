using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using OcrReview.App.ViewModels;

namespace OcrReview.App.Views;

public partial class CommandPaletteView : UserControl
{
    private readonly ObservableCollection<PaletteItem> _filtered = new();
    private IReadOnlyList<PaletteItem> _source = new List<PaletteItem>();

    public CommandPaletteView()
    {
        InitializeComponent();
        ResultList.ItemsSource = _filtered;
    }

    private DocumentViewModel? Vm => DataContext as DocumentViewModel;

    private void OnVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (!IsVisible) return;
        _source = Vm?.BuildPaletteItems() ?? new List<PaletteItem>();
        SearchBox.Text = "";
        ApplyFilter("");
        SearchBox.Focus();
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        Placeholder.Visibility = string.IsNullOrEmpty(SearchBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        ApplyFilter(SearchBox.Text);
    }

    private void ApplyFilter(string query)
    {
        _filtered.Clear();
        var q = query.Trim().ToLowerInvariant();
        foreach (var item in _source)
            if (q.Length == 0 || Matches(q, item.Title.ToLowerInvariant()))
                _filtered.Add(item);
        if (_filtered.Count > 0) ResultList.SelectedIndex = 0;
    }

    private static bool Matches(string query, string text)
    {
        if (text.Contains(query)) return true;
        int qi = 0;
        foreach (var ch in text)
        {
            if (qi >= query.Length) break;
            if (ch == query[qi]) qi++;
        }
        return qi == query.Length;
    }

    private void OnSearchKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Down:
                Move(1); e.Handled = true; break;
            case Key.Up:
                Move(-1); e.Handled = true; break;
            case Key.Enter:
                RunSelected(); e.Handled = true; break;
            case Key.Escape:
                Close(); e.Handled = true; break;
        }
    }

    private void Move(int delta)
    {
        if (_filtered.Count == 0) return;
        int next = (ResultList.SelectedIndex + delta + _filtered.Count) % _filtered.Count;
        ResultList.SelectedIndex = next;
        ResultList.ScrollIntoView(_filtered[next]);
    }

    private void RunSelected()
    {
        if (ResultList.SelectedItem is PaletteItem item) Run(item);
    }

    private void OnResultClick(object sender, MouseButtonEventArgs e)
    {
        var item = ItemFrom(e.OriginalSource as DependencyObject);
        if (item != null) Run(item);
    }

    private void Run(PaletteItem item)
    {
        if (!item.IsEnabled) return;
        Close();
        Dispatcher.BeginInvoke(item.Action);
    }

    private void Close()
    {
        if (Vm != null) Vm.IsCommandPaletteVisible = false;
    }

    private void OnScrimClick(object sender, MouseButtonEventArgs e) => Close();

    private static PaletteItem? ItemFrom(DependencyObject? source)
    {
        while (source != null)
        {
            if (source is FrameworkElement { DataContext: PaletteItem item }) return item;
            source = VisualTreeHelper.GetParent(source);
        }
        return null;
    }
}
