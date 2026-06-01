using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace OcrReview.App.Views;

/// <summary>A small code-only modal text prompt (avoids a Microsoft.VisualBasic dependency).</summary>
public static class Prompt
{
    public static string? Show(string message, string title, string defaultValue = "")
    {
        var window = new Window
        {
            Title = title,
            Width = 380,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = Application.Current?.MainWindow,
            ResizeMode = ResizeMode.NoResize,
            Background = (Brush)new BrushConverter().ConvertFromString("#14171F")!,
            Foreground = Brushes.White,
        };

        var stack = new StackPanel { Margin = new Thickness(20) };
        stack.Children.Add(new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Foreground = (Brush)new BrushConverter().ConvertFromString("#A8AFC2")!,
        });

        var input = new TextBox { Text = defaultValue, Padding = new Thickness(6, 4, 6, 4) };
        stack.Children.Add(input);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0),
        };
        var ok = new Button { Content = "OK", Width = 80, IsDefault = true, Margin = new Thickness(0, 0, 8, 0) };
        var cancel = new Button { Content = "Cancel", Width = 80, IsCancel = true };
        string? result = null;
        ok.Click += (_, _) => { result = input.Text; window.DialogResult = true; };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        stack.Children.Add(buttons);

        window.Content = stack;
        input.Focus();
        input.SelectAll();
        return window.ShowDialog() == true ? result : null;
    }
}
