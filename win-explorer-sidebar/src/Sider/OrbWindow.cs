using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sider;

/// <summary>悬浮球（对齐 mac OrbView）：48px 圆形，点击展开面板，不抢焦点。</summary>
public sealed class OrbWindow : Window
{
    public event Action? ExpandRequested;
    public const double Size = 48;

    public OrbWindow()
    {
        Width = Size; Height = Size;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;

        var icon = new Image
        {
            Source = new BitmapImage(new Uri("pack://application:,,,/Assets/app.png")),
            Width = Size,
            Height = Size,
            Stretch = Stretch.UniformToFill,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new ScaleTransform(1.25, 1.25),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        var circle = new Border
        {
            Child = icon,
            Background = new SolidColorBrush(Color.FromRgb(250, 250, 250)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Size / 2),
            Clip = new EllipseGeometry(new Point(Size / 2, Size / 2), Size / 2, Size / 2),
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            { BlurRadius = 10, ShadowDepth = 2, Opacity = 0.18 }
        };
        Content = circle;
        MouseLeftButtonUp += (_, _) => ExpandRequested?.Invoke();
        Cursor = Cursors.Hand;
        SourceInitialized += (_, _) =>
            NativeMethods.MakeNoActivate(new WindowInteropHelper(this).Handle);
    }
}
