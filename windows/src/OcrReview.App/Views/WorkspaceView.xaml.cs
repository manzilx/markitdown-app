using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace OcrReview.App.Views;

public partial class WorkspaceView : UserControl
{
    public WorkspaceView() => InitializeComponent();

    /// <summary>Closes the owning dropdown after any menu item inside it is clicked.</summary>
    private void OnMenuItemClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ToggleButton toggle })
            toggle.IsChecked = false;
    }
}
