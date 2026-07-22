using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Sider;

/// Read-only display text that still supports mouse selection and Ctrl+C.
public sealed class SelectableText : TextBox
{
    public SelectableText()
    {
        IsReadOnly = true;
        IsReadOnlyCaretVisible = false;
        IsUndoEnabled = false;
        IsTabStop = false;
        AcceptsReturn = true;
        TextWrapping = TextWrapping.Wrap;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        BorderThickness = new Thickness(0);
        Padding = new Thickness(0);
        Background = Brushes.Transparent;
        FocusVisualStyle = null;
        Cursor = Cursors.IBeam;
    }
}
