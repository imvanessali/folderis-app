using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sider;

/// <summary>First-run flow aligned with the macOS edition.</summary>
public sealed class OnboardingWindow : Window
{
    private enum Page { Welcome, Brain, DeepSeekKey, Done }

    private readonly Settings _settings;
    private readonly ContentControl _content = new();
    private readonly SelectableText _progress = new() { Foreground = Brushes.Gray, FontSize = 12 };
    private readonly Button _back = new() { MinWidth = 82, Padding = new Thickness(12, 6, 12, 6) };
    private readonly Button _next = new() { MinWidth = 96, Padding = new Thickness(14, 6, 14, 6) };
    private readonly PasswordBox _keyBox = new() { MinWidth = 360, Margin = new Thickness(0, 8, 0, 6) };
    private Page _page = Page.Welcome;
    private string _selectedBackend;

    public OnboardingWindow(Settings settings)
    {
        _settings = settings;
        _selectedBackend = settings.Backend;
        _keyBox.Password = settings.ApiKey;

        Title = L10n.T($"欢迎使用 {ProductInfo.Name}", $"Welcome to {ProductInfo.Name}");
        Width = 560;
        Height = 570;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ResizeMode = ResizeMode.NoResize;
        Background = new SolidColorBrush(Color.FromRgb(250, 250, 250));

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _content.Margin = new Thickness(34, 28, 34, 20);
        root.Children.Add(_content);

        var footer = new Grid { Margin = new Thickness(24, 12, 24, 18) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _back.Content = L10n.T("返回", "Back");
        _back.Click += (_, _) => GoBack();
        _next.Click += (_, _) => GoNext();
        Grid.SetColumn(_progress, 1);
        Grid.SetColumn(_next, 2);
        _progress.HorizontalAlignment = HorizontalAlignment.Center;
        _progress.VerticalAlignment = VerticalAlignment.Center;
        footer.Children.Add(_back);
        footer.Children.Add(_progress);
        footer.Children.Add(_next);

        var footerBorder = new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromArgb(24, 0, 0, 0)),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = footer
        };
        Grid.SetRow(footerBorder, 1);
        root.Children.Add(footerBorder);
        Content = root;
        RenderPage();
    }

    private StackPanel PageStack() => new()
    {
        MaxWidth = 470,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center
    };

    private static SelectableText Text(string value, double size = 14, FontWeight? weight = null) => new()
    {
        Text = value,
        FontSize = size,
        FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        Margin = new Thickness(0, 5, 0, 5)
    };

    private void RenderPage()
    {
        _content.Content = _page switch
        {
            Page.Welcome => WelcomePage(),
            Page.Brain => BrainPage(),
            Page.DeepSeekKey => DeepSeekPage(),
            _ => DonePage()
        };

        var pages = CurrentPath();
        _progress.Text = $"{pages.IndexOf(_page) + 1} / {pages.Count}";
        _back.Visibility = _page == Page.Welcome ? Visibility.Hidden : Visibility.Visible;
        _next.Content = _page == Page.Done
            ? L10n.T("开始使用", "Get Started")
            : L10n.T("继续", "Continue");
    }

    private StackPanel WelcomePage()
    {
        var panel = PageStack();
        panel.Children.Add(new Image
        {
            Source = new BitmapImage(new Uri("pack://application:,,,/Assets/app.png")),
            Width = 170,
            Height = 170,
            Stretch = Stretch.Uniform,
            Margin = new Thickness(0, 18, 0, 6)
        });
        panel.Children.Add(Text(L10n.T($"欢迎使用 {ProductInfo.Name}", $"Welcome to {ProductInfo.Name}"), 26, FontWeights.Bold));
        var lead = Text(L10n.T(
            "在文件资源管理器窗口旁边放一个 AI 助手：选中文件，直接说你想做什么。",
            "An AI assistant sits beside File Explorer. Select files and say what you want."), 15, FontWeights.SemiBold);
        lead.Foreground = Brushes.DimGray;
        panel.Children.Add(lead);
        var capabilities = Text(L10n.T(
            "支持60+种常见办公操作，压缩、转换、比较、整理、批量操作等等，如果没有命中内置的技能，AI可以当场写代码完成任务。",
            "Folderis supports 60+ common office tasks, including compression, conversion, comparison, organization, and batch operations. If no built-in skill matches, AI can write code on the spot."), 13);
        capabilities.Foreground = Brushes.Gray;
        panel.Children.Add(capabilities);
        var caution = Text(L10n.T(
            "不建议做逻辑特别复杂，人工难以验证的任务，Folderis主打轻量和便捷。",
            "Avoid highly complex tasks that are difficult to verify manually. Folderis is designed for lightweight, convenient work."), 12);
        caution.Foreground = new SolidColorBrush(Color.FromRgb(155, 155, 155));
        panel.Children.Add(caution);
        return panel;
    }

    private StackPanel BrainPage()
    {
        var panel = PageStack();
        panel.HorizontalAlignment = HorizontalAlignment.Stretch;
        panel.Children.Add(Text(L10n.T("选择 AI 来源", "Choose your AI source"), 23, FontWeights.Bold));

#if !MVP_DEEPSEEK
        var claude = CliBackend.DetectPath("claude");
        var codex = CliBackend.DetectPath("codex");
        var cursor = CliBackend.DetectCursorPath();
        if ((_selectedBackend == "ClaudeCode" && claude is null) ||
            (_selectedBackend == "Codex" && codex is null) ||
            (_selectedBackend == "Cursor" && cursor is null))
            _selectedBackend = "BuiltinApi";

        panel.Children.Add(BackendRow("ClaudeCode", claude is not null,
            claude is not null ? "Claude Code ✓" : L10n.T("Claude Code（未检测到）", "Claude Code (not found)"),
            L10n.T("复用你的 Claude 订阅，无需额外付费", "Reuse your Claude subscription at no additional cost")));
        panel.Children.Add(BackendRow("Codex", codex is not null,
            codex is not null ? "Codex ✓" : L10n.T("Codex（未检测到）", "Codex (not found)"),
            L10n.T("复用你的 Codex 订阅，无需额外付费", "Reuse your Codex subscription at no additional cost")));
        panel.Children.Add(BackendRow("Cursor", cursor is not null,
            cursor is not null ? "Cursor ✓" : L10n.T("Cursor Agent（未检测到）", "Cursor Agent (not found)"),
            L10n.T("复用你的 Cursor 订阅，无需额外付费", "Reuse your Cursor subscription at no additional cost")));
        panel.Children.Add(BackendRow("BuiltinApi", true,
            L10n.T("使用 API Key（目前只支持 DeepSeek）", "Use API Key (DeepSeek only for now)"),
            L10n.T("在下一步配置 Deepseek API key", "Configure the DeepSeek API key in the next step")));
#endif
        return panel;
    }

    private Grid BackendRow(string backend, bool detected, string label, string detail)
    {
        var row = new Grid { Margin = new Thickness(0, 5, 0, 5) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var copy = new StackPanel();
        copy.Children.Add(new TextBlock { Text = label, FontSize = 14, FontWeight = FontWeights.SemiBold });
        copy.Children.Add(new TextBlock { Text = detail, FontSize = 12, Foreground = Brushes.Gray });
        var choice = new RadioButton
        {
            Content = copy,
            IsChecked = _selectedBackend == backend,
            IsEnabled = detected,
            GroupName = "backend",
            Padding = new Thickness(5),
            VerticalContentAlignment = VerticalAlignment.Center
        };
        choice.Checked += (_, _) => _selectedBackend = backend;
        row.Children.Add(choice);
        if (!detected)
        {
            var retry = new Button
            {
                Content = L10n.T("重新检测", "Detect again"),
                Padding = new Thickness(8, 3, 8, 3)
            };
            retry.Click += (_, _) => RenderPage();
            Grid.SetColumn(retry, 1);
            row.Children.Add(retry);
        }
        return row;
    }

    private StackPanel DeepSeekPage()
    {
        var panel = PageStack();
        panel.Children.Add(Text("DeepSeek API Key", 23, FontWeights.Bold));
        panel.Children.Add(Text(L10n.T(
            "填入 API Key 后即可使用。可在 platform.deepseek.com 获取。",
            "Enter your API key from platform.deepseek.com."), 13));
        panel.Children.Add(_keyBox);
        panel.Children.Add(Text(L10n.T(
            "API Key 使用 Windows DPAPI 加密保存在当前电脑，不会明文写入磁盘。",
            "The API key is encrypted with Windows DPAPI and never stored in plain text."), 12));
        return panel;
    }

    private StackPanel DonePage()
    {
        var panel = PageStack();
        panel.Children.Add(Text("✓", 54, FontWeights.Bold));
        panel.Children.Add(Text(L10n.T("已经准备好了", "You're ready"), 25, FontWeights.Bold));
        panel.Children.Add(Text(L10n.T(
            "打开文件资源管理器并选中文件，Folderis 会贴靠窗口显示。",
            "Open File Explorer and select files. Folderis will dock beside the window."), 14));
        var example = Text(L10n.T(
            "示例：“将这批PNG无损压缩一下”",
            "Try: “Compress these PNGs losslessly”"), 13);
        example.Foreground = new SolidColorBrush(Color.FromRgb(170, 170, 170));
        panel.Children.Add(example);
        return panel;
    }

    private List<Page> CurrentPath()
    {
#if MVP_DEEPSEEK
        return [Page.Welcome, Page.DeepSeekKey, Page.Done];
#else
        return _selectedBackend == "BuiltinApi"
            ? [Page.Welcome, Page.Brain, Page.DeepSeekKey, Page.Done]
            : [Page.Welcome, Page.Brain, Page.Done];
#endif
    }

    private void GoNext()
    {
        if (_page == Page.Done) { Finish(); return; }
        var pages = CurrentPath();
        var index = pages.IndexOf(_page);
        _page = pages[Math.Min(index + 1, pages.Count - 1)];
        RenderPage();
    }

    private void GoBack()
    {
        var pages = CurrentPath();
        var index = pages.IndexOf(_page);
        _page = pages[Math.Max(index - 1, 0)];
        RenderPage();
    }

    private void Finish()
    {
#if MVP_DEEPSEEK
        _settings.Backend = "BuiltinApi";
#else
        _settings.Backend = _selectedBackend;
#endif
        _settings.ApiKey = _keyBox.Password.Trim();
        _settings.OnboardingDone = true;
        _settings.Save();
        DialogResult = true;
        Close();
    }
}
