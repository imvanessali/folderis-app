using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Sider;

public partial class MainPanel : Window
{
    private readonly ExplorerTracker _tracker = new();
    private readonly PanelDocker _docker;
    private readonly Settings _settings = Settings.Load();
    private readonly AgentClient _agent;
    private readonly SkillRunner _skills;
    private ExplorerContext? _context;
    private CancellationTokenSource? _cts;
    private readonly CliBackend _cliBackend = new();
    private readonly AnnouncementService _announce = new();

    /// <summary>一段会话的身份与数据。任务启动时按引用捕获，此后面板显示
    /// 可以自由切换到别的会话，任务继续往自己捕获的这份里写。</summary>
    private sealed class Conversation
    {
        public string? Binding;
        public string? ConvId;
        public List<JsonObject> History = [];
        public Dictionary<string, string> Sessions = [];
    }

    /// <summary>面板当前显示的会话。</summary>
    private Conversation _conv = new();

    /// <summary>进行中任务的运行态：会话快照 + 工作目录 + 流式回复缓冲。
    /// 显示切走后输出继续写缓冲，切回时由 AttachTurnViews 重挂。</summary>
    private sealed class RunningTurn
    {
        public required Conversation Conv { get; init; }
        public string? WorkRoot;
        public System.Text.StringBuilder Reply = new();
        public string Stage = "";
        public int ElapsedSeconds;
        public Border? PendingApprovalCard;
    }

    private RunningTurn? _turn;
    /// <summary>任务回复气泡/活动行的视图引用——仅在查看任务会话时非空。</summary>
    private SelectableText? _turnReplyView;
    private SelectableText? _turnTypingView;

    private bool ViewingTurn => _turn is not null && ReferenceEquals(_turn.Conv, _conv);

    public MainPanel()
    {
        InitializeComponent();
        Title = ProductInfo.Name;
        BrandTitle.Text = ProductInfo.Name;
        MinimizeButton.ToolTip = L10n.T("收起面板", "Collapse panel");
        CollapsedRail.ToolTip = L10n.T("展开 Folderis", "Expand Folderis");
        NewChatButton.ToolTip = L10n.T("新建对话", "New chat");
        HistoryButton.ToolTip = L10n.T("历史对话", "History");
        SettingsButton.ToolTip = L10n.T("设置", "Settings");
        SendButton.ToolTip = L10n.T("发送", "Send");
        InputHint.Text = L10n.T("描述操作…", "Describe a task…");
        RailLogo.Source = BrandAssets.Logo(_settings.LogoChoice);
        InputBox.TextChanged += (_, _) => InputHint.Visibility =
            InputBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _fileTools = new FileTools
        {
            ApprovalHandler = (cmd, purpose) => Dispatcher.Invoke(() => ShowApprovalCard(cmd, purpose))
        };
        _skills = new SkillRunner();
        _agent = new AgentClient(_settings, _skills, _fileTools);
        _docker = new PanelDocker(this, _tracker);
        _docker.ContextChanged += ctx => Dispatcher.Invoke(() => OnContextChanged(ctx));
        _docker.CollapsedChanged += collapsed => Dispatcher.Invoke(() => ApplyCollapsedUI(collapsed));
        // 不能等 Loaded（窗口不主动 Show 时永不触发）：EnsureHandle 可在
        // 未显示状态下创建句柄，立即启动跟踪。
        Dispatcher.BeginInvoke(() => _docker.Start());
        // 自动贴靠时不抢 Explorer 焦点；用户点输入框后必须稳定接收键盘输入。
        InputBox.PreviewMouseLeftButtonDown += (_, _) =>
        {
            var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            NativeMethods.MakeActivatable(hwnd);
            NativeMethods.SetForegroundWindow(hwnd);
            Activate();
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input, () =>
            {
                InputBox.Focus();
                Keyboard.Focus(InputBox);
            });
        };
        // ⑪ Enter 发送，Shift+Enter 换行
        InputBox.PreviewKeyDown += (_, ev) =>
        {
            if (ev.Key == System.Windows.Input.Key.Enter &&
                !System.Windows.Input.Keyboard.Modifiers.HasFlag(System.Windows.Input.ModifierKeys.Shift))
            {
                ev.Handled = true;
                if (!_sending) _ = SendAsync();
            }
        };
        UpdateEmptyState();

        // 版本公告：后台静默拉取 announce.json，有新版本只出横幅引导到网页下载
        // （在 UI 线程 Start，服务用 SynchronizationContext 把状态变化抛回来）。
        UpdateDownloadButton.Content = L10n.T("前往下载", "Download");
        UpdateLaterButton.Content = L10n.T("稍后", "Later");
        _announce.StateChanged += () => Dispatcher.BeginInvoke(RefreshUpdateBanner);
        _announce.Start();
    }

    /// <summary>
    /// 版本公告横幅：有新版本公告、AI 空闲、非历史页才显示。
    /// AI 正在流式回复或跑工具循环时一律挂起，等空闲再出现。
    /// </summary>
    private void RefreshUpdateBanner()
    {
        var show = _announce.HasNotice && !_sending && !_showingHistory;
        if (show)
            UpdateBannerText.Text = _announce.Message ?? L10n.T(
                $"新版本 {_announce.Version} 已发布",
                $"Version {_announce.Version} is available");
        UpdateBanner.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>「前往下载」：用默认浏览器打开公告里的发布页。</summary>
    private void OnUpdateDownloadClick(object sender, RoutedEventArgs e)
        => _announce.OpenDownloadPage();

    /// <summary>「稍后」在该版本内不再提醒（跨重启记忆）；下发新版本号后重新亮起。</summary>
    private void OnUpdateLaterClick(object sender, RoutedEventArgs e)
        => _announce.Dismiss();

    private void OnContextChanged(ExplorerContext? ctx)
    {
        // 面板显示永远跟随当前选中（任务执行中也不冻结）；进行中的任务
        // 已在启动时捕获了自己的会话与工作目录，不受这里影响。
        _context = ctx;
        ContextLabel.Text = ctx?.SelectedPaths.Count switch
        {
            1 => L10n.T($"{Path.GetFileName(ctx.SelectedPaths[0])}\n" +
                        (Directory.Exists(ctx.SelectedPaths[0]) ? "已绑定文件夹" : "已绑定文件"),
                        $"{Path.GetFileName(ctx.SelectedPaths[0])}\n" +
                        (Directory.Exists(ctx.SelectedPaths[0]) ? "Folder bound" : "File bound")),
            > 1 => L10n.T($"已绑定 {ctx.SelectedPaths.Count} 个项目",
                          $"{ctx.SelectedPaths.Count} items bound"),
            _ => ctx?.FolderPath ?? ""
        };
        // 工具根目录被运行中的任务实时使用，任务结束时（SetSending(false)）再对齐。
        if (_turn is null)
        {
            _fileTools.Root = ctx?.FolderPath;
            _fileTools.ApprovalMode = _settings.ApprovalMode;
        }
        // 精确粒度：文件夹本身与任意显式选择集合分别拥有独立会话。
        SwitchConversation(BindingKey(ctx));
        _attached.Clear();
        if (ctx?.SelectedPaths is { Count: > 0 } sel) _attached.AddRange(sel);
        SyncChips();
        if (_showingHistory) PopulateHistoryList();
    }

    private bool _sending;

    private void OnSendClick(object sender, RoutedEventArgs e)
    {
        if (_sending)
        {
            // 停止按钮只对着正在查看的任务会话生效；查看其他会话时按钮已禁用。
            if (ViewingTurn) _cts?.Cancel();
            return;
        }
        _ = SendAsync();
    }

    private void SetSending(bool sending)
    {
        _sending = sending;
        UpdateSendUi();
        RefreshUpdateBanner();       // 忙碌时收起更新横幅，空闲后再出现
        if (!sending)
        {
            // 任务期间挂起的工具根目录此刻对齐到最新上下文。
            _fileTools.Root = _context?.FolderPath;
            _fileTools.ApprovalMode = _settings.ApprovalMode;
        }
    }

    /// <summary>发送按钮/输入提示随「是否有任务在跑 × 是否正查看该任务会话」变化。</summary>
    private void UpdateSendUi()
    {
        var stoppable = _sending && ViewingTurn;
        SendButton.Content = stoppable ? "\uE71A" : "\uE74A";
        SendButton.ToolTip = stoppable ? L10n.T("停止", "Stop") : L10n.T("发送", "Send");
        SendButton.IsEnabled = !_sending || stoppable;
        InputHint.Text = _sending && !ViewingTurn
            ? L10n.T("另一个对话的任务进行中，完成后可发送…", "A task is running in another chat…")
            : L10n.T("描述操作…", "Describe a task…");
    }

    private readonly List<string> _attached = [];
    private readonly FileTools _fileTools;

    /// <summary>命令确认卡（对齐 mac PendingCommand）：橙色卡片 + 拒绝/允许。</summary>
    private Task<bool> ShowApprovalCard(string command, string? purpose)
    {
        var tcs = new TaskCompletionSource<bool>();
        var stack = new StackPanel { Margin = new Thickness(4) };
        stack.Children.Add(new SelectableText
        {
            Text = L10n.T("AI 请求执行命令", "AI wants to run a command"),
            FontWeight = FontWeights.SemiBold, FontSize = 12
        });
        if (!string.IsNullOrEmpty(purpose))
            stack.Children.Add(new SelectableText { Text = purpose, FontSize = 11,
                Foreground = System.Windows.Media.Brushes.Gray, TextWrapping = TextWrapping.Wrap });
        stack.Children.Add(new SelectableText
        {
            Text = command, FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 6)
        });
        var deny = new Button { Content = L10n.T("拒绝", "Deny"), Width = 70, Margin = new Thickness(0, 0, 8, 0) };
        var allow = new Button { Content = L10n.T("允许执行", "Allow"), Width = 84 };
        var buttons = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Children = { deny, allow }
        };
        stack.Children.Add(buttons);
        var card = new Border
        {
            Child = stack,
            Background = new System.Windows.Media.SolidColorBrush(
                System.Windows.Media.Color.FromArgb(22, 255, 140, 0)),
            BorderBrush = System.Windows.Media.Brushes.Orange,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8), Margin = new Thickness(0, 4, 0, 4)
        };
        deny.Click += (_, _) =>
        {
            ChatList.Children.Remove(card);
            if (_turn?.PendingApprovalCard == card) _turn.PendingApprovalCard = null;
            tcs.TrySetResult(false);
        };
        allow.Click += (_, _) =>
        {
            ChatList.Children.Remove(card);
            if (_turn?.PendingApprovalCard == card) _turn.PendingApprovalCard = null;
            tcs.TrySetResult(true);
        };
        // 用户切走时卡片随消息列表清空，任务停在审批上等待；切回时重挂继续决策。
        if (_turn is not null) _turn.PendingApprovalCard = card;
        if (_turn is null || ViewingTurn)
        {
            ChatList.Children.Add(card);
            ChatScroll.ScrollToBottom();
        }
        return tcs.Task;
    }

    private void SyncChips()
    {
        AttachChips.Children.Clear();
        foreach (var p in _attached)
        {
            var name = Path.GetFileName(p);
            var icon = new TextBlock
            {
                Text = "\uE723",
                FontFamily = new System.Windows.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 13,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 6, 0)
            };
            var text = new SelectableText
            {
                Text = name,
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center
            };
            var close = new Button
            {
                Content = "\u2715", FontSize = 9, Width = 16, Height = 16, Margin = new Thickness(4, 0, 0, 0),
                Background = System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(0),
                VerticalAlignment = VerticalAlignment.Center
            };
            var chipPath = p;
            close.Click += (_, _) => { _attached.Remove(chipPath); SyncChips(); };
            var panel = new Grid();
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(icon, 0);
            Grid.SetColumn(text, 1);
            Grid.SetColumn(close, 2);
            panel.Children.Add(icon);
            panel.Children.Add(text);
            panel.Children.Add(close);
            AttachChips.Children.Add(new Border
            {
                Child = panel,
                Background = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromArgb(30, 0, 103, 192)),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(8, 5, 6, 5),
                Margin = new Thickness(0, 0, 0, 6),
                HorizontalAlignment = HorizontalAlignment.Stretch
            });
        }
        ChipsScroll.Visibility = _attached.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        var input = new PasswordBox { Password = _settings.ApiKey, MinWidth = 280, Margin = new Thickness(0, 6, 0, 2) };
        var hint = new SelectableText
        {
            Text = L10n.T("密钥加密保存在本机（Windows DPAPI），不会明文写入磁盘。",
                          "Stored encrypted on this machine (Windows DPAPI)."),
            FontSize = 11, Foreground = System.Windows.Media.Brushes.Gray, Margin = new Thickness(0, 0, 0, 10)
        };
        var getKeyLink = new System.Windows.Documents.Hyperlink(
            new System.Windows.Documents.Run(L10n.T("获取 API Key →", "Get API Key →")))
        {
            NavigateUri = new Uri("https://platform.deepseek.com/api_keys")
        };
        getKeyLink.RequestNavigate += (_, e) =>
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(e.Uri.AbsoluteUri)
            { UseShellExecute = true });
            e.Handled = true;
        };
        var keyHeader = new Grid();
        keyHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        keyHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        keyHeader.Children.Add(new SelectableText { Text = "DeepSeek API Key", FontWeight = FontWeights.SemiBold });
        var getKeyText = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        getKeyText.Inlines.Add(getKeyLink);
        Grid.SetColumn(getKeyText, 1);
        keyHeader.Children.Add(getKeyText);
        var keySection = new StackPanel
        {
            Margin = new Thickness(24, 6, 0, 0),
            Children =
            {
                keyHeader,
                input,
                hint
            }
        };

        var content = new StackPanel { Margin = new Thickness(18), MinWidth = 360 };
        var selectedBackend = _settings.Backend;
        var rbClaude = new RadioButton { GroupName = "settings-backend", Margin = new Thickness(0, 3, 0, 3) };
        var rbCodex = new RadioButton { GroupName = "settings-backend", Margin = new Thickness(0, 3, 0, 3) };
        var rbCursor = new RadioButton { GroupName = "settings-backend", Margin = new Thickness(0, 3, 0, 3) };
        var rbDeepSeek = new RadioButton
        {
            GroupName = "settings-backend",
            Content = L10n.T("使用 API Key（仅Deepseek）", "Use API Key (DeepSeek only)"),
            Margin = new Thickness(0, 3, 0, 3)
        };
        var retryClaude = new Button { Content = L10n.T("重新检测", "Detect again"), Padding = new Thickness(8, 2, 8, 2) };
        var retryCodex = new Button { Content = L10n.T("重新检测", "Detect again"), Padding = new Thickness(8, 2, 8, 2) };
        var retryCursor = new Button { Content = L10n.T("重新检测", "Detect again"), Padding = new Thickness(8, 2, 8, 2) };
        var caption = new SelectableText
        {
            FontSize = 11,
            Foreground = System.Windows.Media.Brushes.Gray,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 12)
        };

        static Grid BackendRow(RadioButton choice, Button retry)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(retry, 1);
            row.Children.Add(choice);
            row.Children.Add(retry);
            return row;
        }

        void SyncBackendUi()
        {
            rbClaude.IsChecked = selectedBackend == "ClaudeCode";
            rbCodex.IsChecked = selectedBackend == "Codex";
            rbCursor.IsChecked = selectedBackend == "Cursor";
            rbDeepSeek.IsChecked = selectedBackend == "BuiltinApi";
            keySection.Visibility = selectedBackend == "BuiltinApi" ? Visibility.Visible : Visibility.Collapsed;
            caption.Visibility = selectedBackend == "BuiltinApi" ? Visibility.Collapsed : Visibility.Visible;
            caption.Text = selectedBackend switch
            {
                "ClaudeCode" => L10n.T("复用你的 Claude 订阅，无需额外付费", "Reuse your Claude subscription at no additional cost"),
                "Codex" => L10n.T("复用你的 Codex 订阅，无需额外付费", "Reuse your Codex subscription at no additional cost"),
                "Cursor" => L10n.T("复用你的 Cursor 订阅，无需额外付费", "Reuse your Cursor subscription at no additional cost"),
                _ => ""
            };
        }

        void RefreshDetection()
        {
            var claude = CliBackend.DetectPath("claude");
            var codex = CliBackend.DetectPath("codex");
            var cursor = CliBackend.DetectCursorPath();
            rbClaude.Content = claude is not null ? "Claude Code ✓" : L10n.T("Claude Code（未检测到）", "Claude Code (not found)");
            rbClaude.IsEnabled = claude is not null;
            retryClaude.Visibility = claude is null ? Visibility.Visible : Visibility.Collapsed;
            rbCodex.Content = codex is not null ? "Codex ✓" : L10n.T("Codex（未检测到）", "Codex (not found)");
            rbCodex.IsEnabled = codex is not null;
            retryCodex.Visibility = codex is null ? Visibility.Visible : Visibility.Collapsed;
            rbCursor.Content = cursor is not null ? "Cursor ✓" : L10n.T("Cursor Agent（未检测到）", "Cursor Agent (not found)");
            rbCursor.IsEnabled = cursor is not null;
            retryCursor.Visibility = cursor is null ? Visibility.Visible : Visibility.Collapsed;
            if ((selectedBackend == "ClaudeCode" && claude is null) ||
                (selectedBackend == "Codex" && codex is null) ||
                (selectedBackend == "Cursor" && cursor is null))
                selectedBackend = "BuiltinApi";
            SyncBackendUi();
        }

        rbClaude.Checked += (_, _) => { selectedBackend = "ClaudeCode"; SyncBackendUi(); };
        rbCodex.Checked += (_, _) => { selectedBackend = "Codex"; SyncBackendUi(); };
        rbCursor.Checked += (_, _) => { selectedBackend = "Cursor"; SyncBackendUi(); };
        rbDeepSeek.Checked += (_, _) => { selectedBackend = "BuiltinApi"; SyncBackendUi(); };
        retryClaude.Click += (_, _) => RefreshDetection();
        retryCodex.Click += (_, _) => RefreshDetection();
        retryCursor.Click += (_, _) => RefreshDetection();

        content.Children.Add(new SelectableText
        {
            Text = L10n.T("选择 AI 来源", "Choose AI Source"),
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 5)
        });
        content.Children.Add(BackendRow(rbClaude, retryClaude));
        content.Children.Add(BackendRow(rbCodex, retryCodex));
        content.Children.Add(BackendRow(rbCursor, retryCursor));
        content.Children.Add(rbDeepSeek);
        content.Children.Add(keySection);
        content.Children.Add(caption);
        RefreshDetection();

        var save = new Button { Content = L10n.T("保存", "Save"), Width = 88, Margin = new Thickness(0, 0, 8, 0) };
        var quit = new Button { Content = L10n.T($"退出 {ProductInfo.Name}", $"Quit {ProductInfo.Name}"), Width = 110,
            Foreground = System.Windows.Media.Brushes.Firebrick };
        var buttons = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Children = { save, quit }
        };
        var approvalTitle = new SelectableText
        {
            Text = L10n.T("命令审批", "Command Approval"),
            FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 4)
        };
        var rbAsk = new RadioButton { Content = L10n.T("每次询问（最安全）", "Ask every time (safest)"),
            GroupName = "appr", IsChecked = _settings.ApprovalMode == "ask", Margin = new Thickness(0, 2, 0, 2) };
        var rbSafe = new RadioButton { Content = L10n.T("只读命令自动允许", "Auto-allow read-only"),
            GroupName = "appr", IsChecked = _settings.ApprovalMode == "safeAuto", Margin = new Thickness(0, 2, 0, 2) };
        var rbYolo = new RadioButton { Content = L10n.T("全部自动允许（自担风险）", "Auto-allow all (at your own risk)"),
            GroupName = "appr", IsChecked = _settings.ApprovalMode == "yolo", Margin = new Thickness(0, 2, 0, 10) };

        var build = new SelectableText
        {
            Text = $"Folderis {ProductInfo.Edition} · v{ProductInfo.Version} ({ProductInfo.Build})\n" +
                L10n.T($"构建于 {File.GetLastWriteTime(Environment.ProcessPath!):yyyy-MM-dd HH:mm}",
                       $"Build {File.GetLastWriteTime(Environment.ProcessPath!):yyyy-MM-dd HH:mm}"),
            FontSize = 10, Foreground = System.Windows.Media.Brushes.LightGray, Margin = new Thickness(0, 10, 0, 0)
        };

        // —— 面板图标：默认 / Clippy / 自定义上传（对齐 mac SettingsView）——
        var logoTitle = new SelectableText
        {
            Text = L10n.T("面板图标", "Panel Icon"),
            FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 4)
        };
        var selectedLogo = _settings.LogoChoice;
        var rbLogoOrb = new RadioButton { GroupName = "logo", Margin = new Thickness(0, 2, 0, 2) };
        var rbLogoClippy = new RadioButton { GroupName = "logo", Margin = new Thickness(0, 2, 0, 2) };
        var rbLogoCustom = new RadioButton { GroupName = "logo", Margin = new Thickness(0, 2, 0, 2) };
        var pickLogo = new Button { Content = L10n.T("选择图片…", "Choose image…"), Padding = new Thickness(8, 2, 8, 2) };
        var logoHint = new SelectableText
        {
            Text = L10n.T("建议使用正方形图片；非正方形会自动居中裁剪，过大的图片会自动压缩。",
                          "Square images work best; non-square images are center-cropped and oversized ones compressed automatically."),
            FontSize = 11, Foreground = System.Windows.Media.Brushes.Gray,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 10)
        };

        static StackPanel LogoLabel(string choice, string text)
        {
            var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            row.Children.Add(new System.Windows.Controls.Image
            {
                Source = BrandAssets.Logo(choice), Width = 20, Height = 20,
                Stretch = System.Windows.Media.Stretch.UniformToFill,
                Margin = new Thickness(0, 0, 6, 0),
                Clip = new System.Windows.Media.RectangleGeometry(new Rect(0, 0, 20, 20), 4, 4)
            });
            row.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
            return row;
        }

        void SyncLogoUi()
        {
            // 内容整块重建：导入新自定义图后预览立即更新。
            rbLogoOrb.Content = LogoLabel("orb", L10n.T("默认", "Default"));
            rbLogoClippy.Content = LogoLabel("clippy", "Clippy");
            rbLogoCustom.Content = LogoLabel("custom", L10n.T("自定义图片", "Custom image"));
            rbLogoCustom.IsEnabled = File.Exists(BrandAssets.CustomLogoPath);
            rbLogoOrb.IsChecked = selectedLogo == "orb";
            rbLogoClippy.IsChecked = selectedLogo == "clippy";
            rbLogoCustom.IsChecked = selectedLogo == "custom";
        }

        rbLogoOrb.Checked += (_, _) => selectedLogo = "orb";
        rbLogoClippy.Checked += (_, _) => selectedLogo = "clippy";
        rbLogoCustom.Checked += (_, _) => selectedLogo = "custom";
        pickLogo.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Filter = L10n.T("图片|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff",
                                "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff")
            };
            if (dlg.ShowDialog() != true) return;
            try
            {
                BrandAssets.ImportCustom(dlg.FileName);
                selectedLogo = "custom";
                SyncLogoUi();
            }
            catch (Exception ex)
            {
                MessageBox.Show(L10n.T($"图片导入失败：{ex.Message}", $"Image import failed: {ex.Message}"),
                    ProductInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        SyncLogoUi();

        content.Children.Add(approvalTitle);
        content.Children.Add(rbAsk);
        content.Children.Add(rbSafe);
        content.Children.Add(rbYolo);
        content.Children.Add(logoTitle);
        content.Children.Add(rbLogoOrb);
        content.Children.Add(rbLogoClippy);
        content.Children.Add(BackendRow(rbLogoCustom, pickLogo));
        content.Children.Add(logoHint);
        content.Children.Add(buttons);
        content.Children.Add(build);
        var dialog = new Window
        {
            Title = L10n.T($"设置 · 模型 {_settings.Model}", $"Settings · Model {_settings.Model}"),
            SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this, ResizeMode = ResizeMode.NoResize,
            Content = content
        };
        save.Click += (_, _) =>
        {
            _settings.ApiKey = input.Password.Trim();
            _settings.Backend = selectedBackend;
            _settings.ApprovalMode = rbYolo.IsChecked == true ? "yolo"
                                   : rbSafe.IsChecked == true ? "safeAuto" : "ask";
            _settings.LogoChoice = rbLogoCustom.IsEnabled && selectedLogo == "custom" ? "custom" : selectedLogo == "clippy" ? "clippy" : "orb";
            _fileTools.ApprovalMode = _settings.ApprovalMode;
            _settings.Save();
            ApplyLogo();
            dialog.Close();
        };
        quit.Click += (_, _) => Application.Current.Shutdown();
        dialog.ShowDialog();
    }

    private static string ConvDir
    {
        get
        {
            var d = Path.Combine(SkillRunner.SupportRoot, "conversations");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    private static string TaskDir
    {
        get
        {
            var d = Path.Combine(SkillRunner.SupportRoot, "tasks");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    private string NextTaskId()
    {
        var day = DateTime.Now.ToString("yyMMdd");
        var prefix = $"F-{day}-";
        var counter = Directory.EnumerateFiles(TaskDir, prefix + "*.json")
            .Select(Path.GetFileNameWithoutExtension)
            .Select(name => name is not null && name.StartsWith(prefix, StringComparison.Ordinal)
                && int.TryParse(name[prefix.Length..], out var value) ? value : 0)
            .DefaultIfEmpty(0).Max();
        while (true)
        {
            var candidate = $"{prefix}{++counter:000}";
            try
            {
                using var reservation = new FileStream(
                    Path.Combine(TaskDir, candidate + ".json"),
                    FileMode.CreateNew, FileAccess.Write, FileShare.None);
                return candidate;
            }
            catch (IOException) when (File.Exists(Path.Combine(TaskDir, candidate + ".json")))
            {
                // Another Folderis edition claimed it between enumeration and create.
            }
        }
    }

    private void RegisterTask(string taskId, string text)
    {
        _conv.ConvId ??= Guid.NewGuid().ToString("N");
        var doc = new JsonObject
        {
            ["id"] = taskId,
            ["text"] = text,
            ["binding"] = _conv.Binding,
            ["conversationId"] = _conv.ConvId,
            ["created"] = DateTime.Now.ToString("o")
        };
        File.WriteAllText(Path.Combine(TaskDir, taskId + ".json"), doc.ToJsonString());
    }

    private string? ReferencedTaskContext(string text)
    {
        var match = System.Text.RegularExpressions.Regex.Match(
            text, @"\bF-\d{6}-\d{3,}\b",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        if (!match.Success) return null;
        var taskId = match.Value.ToUpperInvariant();
        try
        {
            var task = JsonNode.Parse(File.ReadAllText(
                Path.Combine(TaskDir, taskId + ".json")))!.AsObject();
            var original = (string?)task["text"] ?? "";
            var binding = (string?)task["binding"];
            var bindingDetails = BindingDetails(binding);
            return L10n.T(
                $"用户引用了历史任务 {taskId}。\n原始需求：{original}\n当时精确绑定：\n{bindingDetails}\n" +
                "请结合当前消息继续或排查该任务；如果当前绑定不同，不要擅自操作旧路径，先说明差异。",
                $"The user referenced task {taskId}.\nOriginal request: {original}\nPrevious exact binding:\n{bindingDetails}\n" +
                "Continue or debug it using the current message. If the current binding differs, explain the difference before touching old paths.");
        }
        catch
        {
            return L10n.T(
                $"用户引用了任务 {taskId}，但本机任务记录中没有找到该编号。请明确说明编号未找到，不要猜测。",
                $"The user referenced task {taskId}, but it was not found in the local task registry. Say so clearly and do not guess.");
        }
    }

    private const string FolderBindingPrefix = "folder:";
    private const string SelectionBindingPrefix = "selection:";

    private static string CanonicalPath(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            var root = Path.GetPathRoot(full);
            return string.Equals(full, root, StringComparison.OrdinalIgnoreCase)
                ? full : full.TrimEnd(Path.DirectorySeparatorChar);
        }
        catch { return path.TrimEnd(Path.DirectorySeparatorChar); }
    }

    /// 绑定项 token：`<NTFS身份>|<规范化路径>`。身份在重命名/同卷移动后不变，
    /// 是匹配的首选依据；路径用于显示和身份不可用时的兜底比较。
    private static string BindingToken(string path)
    {
        var canonical = CanonicalPath(path);
        var identity = FileIdentity.TryGet(canonical);
        return identity is null ? canonical : identity + "|" + canonical;
    }

    private static string TokenPath(string token)
    {
        var sep = token.IndexOf('|');
        return sep >= 0 ? token[(sep + 1)..] : token;
    }

    private static string? TokenIdentity(string token)
    {
        var sep = token.IndexOf('|');
        return sep > 0 && token.StartsWith("id:", StringComparison.Ordinal)
            ? token[..sep] : null;
    }

    private static string? BindingKey(ExplorerContext? context)
    {
        if (string.IsNullOrWhiteSpace(context?.FolderPath)) return null;
        var selected = context.SelectedPaths
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .Select(BindingToken)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(TokenPath, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        return selected.Length == 0
            ? FolderBindingPrefix + BindingToken(context.FolderPath!)
            : SelectionBindingPrefix + string.Join("\n", selected);
    }

    /// <summary>Maps pre-exact-binding histories into the new key space.</summary>
    private static string? NormalizeStoredBinding(string? binding)
    {
        if (string.IsNullOrWhiteSpace(binding)) return null;
        if (binding.StartsWith(FolderBindingPrefix, StringComparison.OrdinalIgnoreCase) ||
            binding.StartsWith(SelectionBindingPrefix, StringComparison.OrdinalIgnoreCase))
            return binding;
        var path = CanonicalPath(binding);
        return File.Exists(path) ? SelectionBindingPrefix + path : FolderBindingPrefix + path;
    }

    /// 单项匹配：两侧都带 NTFS 身份时按身份比较（重命名后仍相等），
    /// 否则退回路径比较（存量纯路径绑定、身份不可用的卷）。
    private static bool SameTokenItem(string a, string b)
    {
        var idA = TokenIdentity(a);
        var idB = TokenIdentity(b);
        if (idA is not null && idB is not null)
            return string.Equals(idA, idB, StringComparison.OrdinalIgnoreCase);
        return string.Equals(TokenPath(a), TokenPath(b), StringComparison.OrdinalIgnoreCase);
    }

    private static bool SameBinding(string? a, string? b)
    {
        var na = NormalizeStoredBinding(a);
        var nb = NormalizeStoredBinding(b);
        if (na is null || nb is null) return na == nb;

        static (string prefix, string payload) Split(string s) =>
            s.StartsWith(SelectionBindingPrefix, StringComparison.OrdinalIgnoreCase)
                ? (SelectionBindingPrefix, s[SelectionBindingPrefix.Length..])
                : (FolderBindingPrefix, s[FolderBindingPrefix.Length..]);
        var (prefixA, payloadA) = Split(na);
        var (prefixB, payloadB) = Split(nb);
        if (!string.Equals(prefixA, prefixB, StringComparison.OrdinalIgnoreCase)) return false;

        var itemsA = payloadA.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var itemsB = payloadB.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        if (itemsA.Length != itemsB.Length) return false;
        // 重命名会改变按路径排序的次序，按多重集合贪心配对而非按下标。
        var used = new bool[itemsB.Length];
        foreach (var item in itemsA)
        {
            var matched = false;
            for (var i = 0; i < itemsB.Length; i++)
            {
                if (used[i] || !SameTokenItem(item, itemsB[i])) continue;
                used[i] = true;
                matched = true;
                break;
            }
            if (!matched) return false;
        }
        return true;
    }

    private static string BindingLabel(string binding)
    {
        var normalized = NormalizeStoredBinding(binding) ?? binding;
        if (normalized.StartsWith(SelectionBindingPrefix, StringComparison.OrdinalIgnoreCase))
        {
            var items = normalized[SelectionBindingPrefix.Length..]
                .Split('\n', StringSplitOptions.RemoveEmptyEntries);
            return items.Length == 1
                ? Path.GetFileName(TokenPath(items[0]).TrimEnd(Path.DirectorySeparatorChar))
                : L10n.T($"{items.Length} 个项目", $"{items.Length} items");
        }
        var folder = normalized.StartsWith(FolderBindingPrefix, StringComparison.OrdinalIgnoreCase)
            ? normalized[FolderBindingPrefix.Length..] : normalized;
        return Path.GetFileName(TokenPath(folder).TrimEnd(Path.DirectorySeparatorChar));
    }

    private static string BindingDetails(string? binding)
    {
        if (string.IsNullOrWhiteSpace(binding)) return L10n.T("未记录", "not recorded");
        var normalized = NormalizeStoredBinding(binding) ?? binding;
        if (normalized.StartsWith(SelectionBindingPrefix, StringComparison.OrdinalIgnoreCase))
            return string.Join("\n", normalized[SelectionBindingPrefix.Length..]
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(TokenPath));
        return normalized.StartsWith(FolderBindingPrefix, StringComparison.OrdinalIgnoreCase)
            ? TokenPath(normalized[FolderBindingPrefix.Length..]) : normalized;
    }

    private bool _showingHistory;

    private void SaveConversation() => SaveConversation(_conv);

    private void SaveConversation(Conversation conv)
    {
        if (conv.Binding is null || conv.History.Count == 0) return;
        conv.ConvId ??= Guid.NewGuid().ToString("N");
        var title = conv.History.FirstOrDefault(m => (string?)m["role"] == "user") is { } first
            ? ((string?)first["content"] ?? "").Split("\n\n---\n\n").Last().Trim() : "";
        if (title.Length > 40) title = title[..40];
        var sessions = new JsonObject();
        foreach (var (backend, id) in conv.Sessions) sessions[backend] = id;
        var doc = new JsonObject
        {
            ["binding"] = conv.Binding,
            ["title"] = title,
            ["updated"] = DateTime.Now.ToString("o"),
            ["backendSessions"] = sessions,
            ["items"] = new JsonArray(conv.History.Select(m => (JsonNode)m.DeepClone()).ToArray())
        };
        File.WriteAllText(Path.Combine(ConvDir, conv.ConvId + ".json"), doc.ToJsonString());
    }

    private static IEnumerable<(string id, JsonObject doc)> AllConversations()
    {
        foreach (var f in Directory.GetFiles(ConvDir, "*.json").OrderByDescending(File.GetLastWriteTime))
        {
            JsonObject? doc = null;
            try { doc = JsonNode.Parse(File.ReadAllText(f))!.AsObject(); } catch { }
            if (doc is not null) yield return (Path.GetFileNameWithoutExtension(f), doc);
        }
    }

    private void LoadConversationDoc(string id, JsonObject doc)
    {
        _conv.ConvId = id;
        _conv.Sessions = [];
        if (doc["backendSessions"] is JsonObject sessions)
            foreach (var pair in sessions)
                if ((string?)pair.Value is { Length: > 0 } sessionId)
                    _conv.Sessions[pair.Key] = sessionId;
        _conv.History = [];
        foreach (var it in (doc["items"] as JsonArray) ?? [])
            _conv.History.Add((JsonObject)it!.AsObject().DeepClone());
        RenderHistory();
    }

    /// <summary>从 _conv.History 重绘消息列表。</summary>
    private void RenderHistory()
    {
        ChatList.Children.Clear();
        foreach (var o in _conv.History)
        {
            var role = (string?)o["role"];
            var content = (string?)o["content"] ?? "";
            if (role == "user" && content.Length > 0)
                AppendBubble(content.Split("\n\n---\n\n").Last(), isUser: true,
                             taskId: (string?)o["taskId"]);
            else if (role == "assistant" && content.Length > 0 && o["tool_calls"] is null)
                RenderAssistantMessage(content);
        }
        UpdateEmptyState();
    }

    /// <summary>绑定切换：存旧会话，载新绑定的最近一条会话（无则空白新会话）。
    /// 运行中的任务不受影响；切回任务所在绑定时重挂其在途输出。</summary>
    private void SwitchConversation(string? binding)
    {
        binding = NormalizeStoredBinding(binding);
        if (SameBinding(binding, _conv.Binding))
        {
            // 同一身份的最新形式：目标刚被重命名时路径部分会变，采纳新路径
            // 让后续 SaveConversation 把存量绑定自愈成当前路径。
            _conv.Binding = binding;
            return;
        }
        CrossfadeConversationArea();
        SaveConversation();
        DetachTurnViews();
        if (_turn is not null && SameBinding(binding, _turn.Conv.Binding))
        {
            // 切回运行中任务绑定的会话：复用其在途状态（含未落盘的流式输出）。
            _conv = _turn.Conv;
            _conv.Binding = binding;
            RenderHistory();
            AttachTurnViews();
            UpdateSendUi();
            return;
        }
        _conv = new Conversation { Binding = binding };
        ChatList.Children.Clear();
        if (binding is not null)
        {
            var latest = AllConversations().FirstOrDefault(c => SameBinding((string?)c.doc["binding"], binding));
            if (latest.doc is not null) LoadConversationDoc(latest.id, latest.doc);
        }
        UpdateEmptyState();
        UpdateSendUi();
    }

    /// <summary>会话切换的渐白过渡：把旧内容快照垫在白底上盖住消息区淡出，
    /// 新内容在下面即时就位——视觉上是"渐白再浮现"，不硬切。</summary>
    private System.Windows.Controls.Border? _convFadeOverlay;

    private void CrossfadeConversationArea()
    {
        if (ConversationHost.ActualWidth < 1 || ConversationHost.ActualHeight < 1) return;
        try
        {
            // 上一次过渡还没结束就先摘掉，避免快照把旧遮罩也拍进去。
            if (_convFadeOverlay is not null)
            {
                ConversationHost.Children.Remove(_convFadeOverlay);
                _convFadeOverlay = null;
            }
            var snapshot = new System.Windows.Media.Imaging.RenderTargetBitmap(
                (int)ConversationHost.ActualWidth, (int)ConversationHost.ActualHeight,
                96, 96, System.Windows.Media.PixelFormats.Pbgra32);
            snapshot.Render(ConversationHost);
            snapshot.Freeze();
            var overlay = new System.Windows.Controls.Border
            {
                // 与面板同底色：淡出过程读作"渐白"。
                Background = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromRgb(250, 250, 250)),
                IsHitTestVisible = false,
                Child = new System.Windows.Controls.Image { Source = snapshot }
            };
            System.Windows.Controls.Panel.SetZIndex(overlay, 99);
            ConversationHost.Children.Add(overlay);
            _convFadeOverlay = overlay;
            var fade = new System.Windows.Media.Animation.DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(220))
            {
                EasingFunction = new System.Windows.Media.Animation.QuadraticEase
                { EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut }
            };
            fade.Completed += (_, _) =>
            {
                ConversationHost.Children.Remove(overlay);
                if (ReferenceEquals(_convFadeOverlay, overlay)) _convFadeOverlay = null;
            };
            overlay.BeginAnimation(OpacityProperty, fade);
        }
        catch { /* 快照失败就退回硬切，不影响功能 */ }
    }

    /// <summary>切回任务会话时重挂在途输出：回复气泡（缓冲全文）+ 活动行 + 待决审批卡。</summary>
    private void AttachTurnViews()
    {
        if (_turn is null || !ViewingTurn) return;
        RemoveEmptyState();
        if (_turn.Reply.Length > 0) EnsureTurnReplyView(_turn);
        _turnTypingView = new SelectableText
        {
            Foreground = System.Windows.Media.Brushes.Gray,
            FontSize = 11, Margin = new Thickness(4, 2, 0, 6)
        };
        ChatList.Children.Add(_turnTypingView);
        UpdateTurnStatusText();
        if (_turn.PendingApprovalCard is { } card && !ChatList.Children.Contains(card))
            ChatList.Children.Add(card);
        ChatScroll.ScrollToBottom();
    }

    /// <summary>切走时丢弃视图引用（控件随 ChatList 清空消失，数据留在任务缓冲里）。</summary>
    private void DetachTurnViews()
    {
        _turnReplyView = null;
        _turnTypingView = null;
    }

    private SelectableText EnsureTurnReplyView(RunningTurn turn)
    {
        if (_turnReplyView is null)
        {
            _turnReplyView = AppendBubble(turn.Reply.ToString(), isUser: false);
            if (_turnTypingView is not null)
            {
                // 活动行保持在气泡下方（多轮工具期间持续可见，对齐 mac loading-row）
                ChatList.Children.Remove(_turnTypingView);
                ChatList.Children.Add(_turnTypingView);
            }
        }
        return _turnReplyView;
    }

    private void AppendTurnReply(RunningTurn turn, string delta)
    {
        turn.Reply.Append(delta);
        if (!ViewingTurn) return;
        if (_turnReplyView is null) EnsureTurnReplyView(turn);   // 创建时已带缓冲全文
        else _turnReplyView.Text += delta;
    }

    private void SetTurnReply(RunningTurn turn, string text)
    {
        turn.Reply.Clear();
        turn.Reply.Append(text);
        if (ViewingTurn) EnsureTurnReplyView(turn).Text = text;
    }

    private void UpdateTurnStatusText()
    {
        if (_turn is null || _turnTypingView is null) return;
        var seconds = _turn.ElapsedSeconds;
        _turnTypingView.Text = seconds >= 30
            ? L10n.T($"{_turn.Stage} · {seconds} 秒 · 任务仍在正常运行", $"{_turn.Stage} · {seconds}s · still running normally")
            : L10n.T($"{_turn.Stage} · {seconds} 秒", $"{_turn.Stage} · {seconds}s");
    }

    private void OnNewChatClick(object sender, RoutedEventArgs e)
    {
        if (ViewingTurn) _cts?.Cancel();   // 对着运行中的会话新建 = 停止该任务
        CrossfadeConversationArea();
        SaveConversation();          // 旧会话保留（mac 语义：新建≠删除）
        DetachTurnViews();
        _conv = new Conversation { Binding = _conv.Binding };
        ChatList.Children.Clear();
        if (_showingHistory) ExitHistoryPage(); else UpdateEmptyState();
        UpdateSendUi();
    }

    private void OnMinimizeClick(object sender, RoutedEventArgs e) => _docker.Collapse();

    private void OnExpandClick(object sender, MouseButtonEventArgs e) => _docker.Expand();

    /// <summary>收起态 ↔ 展开态的内部 UI 切换：窄轨只留 icon + ">"。</summary>
    private void ApplyCollapsedUI(bool collapsed)
    {
        ExpandedRoot.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        CollapsedRail.Visibility = collapsed ? Visibility.Visible : Visibility.Collapsed;
    }

    public void ToggleCollapsed()
    {
        if (_docker.IsCollapsed) _docker.Expand(); else _docker.Collapse();
    }

    public void ClearConversation() => OnNewChatClick(this, new RoutedEventArgs());

    private void OnHistoryClick(object sender, RoutedEventArgs e)
    {
        if (_showingHistory) return;
        SaveConversation();
        _showingHistory = true;
        BrandTitle.Text = L10n.T("历史对话", "History");
        DoneButton.Content = L10n.T("完成", "Done");
        MainToolbar.Visibility = Visibility.Collapsed;
        DoneButton.Visibility = Visibility.Visible;
        ContextLabel.Visibility = Visibility.Collapsed;
        ChipsScroll.Visibility = Visibility.Collapsed;
        InputArea.Visibility = Visibility.Collapsed;
        ChatScroll.Visibility = Visibility.Collapsed;
        RemoveEmptyState();
        PopulateHistoryList();
        HistoryScroll.Visibility = Visibility.Visible;
        RefreshUpdateBanner();
    }

    private void OnDoneClick(object sender, RoutedEventArgs e) => ExitHistoryPage();

    private void ExitHistoryPage()
    {
        _showingHistory = false;
        BrandTitle.Text = ProductInfo.Name;
        DoneButton.Visibility = Visibility.Collapsed;
        MainToolbar.Visibility = Visibility.Visible;
        ContextLabel.Visibility = Visibility.Visible;
        InputArea.Visibility = Visibility.Visible;
        HistoryScroll.Visibility = Visibility.Collapsed;
        ChatScroll.Visibility = Visibility.Visible;
        SyncChips();
        UpdateEmptyState();
        RefreshUpdateBanner();
    }

    private void PopulateHistoryList()
    {
        HistoryList.Children.Clear();

        var newChatLabel = new StackPanel { Orientation = Orientation.Horizontal };
        newChatLabel.Children.Add(new TextBlock
        {
            Text = "\uE70F",
            FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
            Foreground = new SolidColorBrush(Color.FromRgb(0, 103, 192)),
            FontSize = 12,
            Margin = new Thickness(0, 0, 7, 0)
        });
        newChatLabel.Children.Add(new TextBlock
        {
            Text = L10n.T("新建对话", "New chat"),
            Foreground = new SolidColorBrush(Color.FromRgb(0, 103, 192)),
            FontSize = 12
        });
        var newChat = new Button
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 9, 10, 9),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Cursor = Cursors.Hand,
            Content = newChatLabel
        };
        newChat.Click += OnNewChatClick;
        HistoryList.Children.Add(newChat);
        HistoryList.Children.Add(new Border
        {
            Height = 1,
            Background = new SolidColorBrush(Color.FromArgb(28, 0, 0, 0))
        });

        var conversations = AllConversations()
            .Where(c => SameBinding((string?)c.doc["binding"], _conv.Binding))
            .ToArray();
        if (conversations.Length == 0)
        {
            HistoryList.Children.Add(new SelectableText
            {
                Text = L10n.T("当前绑定还没有历史对话", "No chat history for this binding yet"),
                Foreground = Brushes.Gray,
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(16, 42, 16, 0),
                FontSize = 12
            });
            return;
        }

        foreach (var (id, doc) in conversations)
        {
            var title = ((string?)doc["title"])?.Trim();
            if (string.IsNullOrEmpty(title)) title = L10n.T("未命名对话", "Untitled chat");
            var updated = DateTime.TryParse((string?)doc["updated"], out var time)
                ? time : DateTime.MinValue;

            var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            labels.Children.Add(new SelectableText
            {
                Text = title,
                FontSize = 12,
                TextWrapping = TextWrapping.NoWrap,   // TextBox 不支持省略号，单行裁剪
                MaxWidth = 205
            });
            labels.Children.Add(new SelectableText
            {
                Text = RelativeHistoryDate(updated),
                Foreground = Brushes.Gray,
                FontSize = 10,
                Margin = new Thickness(0, 2, 0, 0)
            });

            var openContent = new Grid();
            openContent.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            openContent.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            openContent.Children.Add(labels);
            if (_conv.ConvId == id)
            {
                var current = new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(30, 0, 103, 192)),
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(6, 2, 6, 2),
                    VerticalAlignment = VerticalAlignment.Center,
                    Child = new SelectableText
                    {
                        Text = L10n.T("当前", "Current"),
                        Foreground = new SolidColorBrush(Color.FromRgb(0, 103, 192)),
                        FontSize = 9
                    }
                };
                Grid.SetColumn(current, 1);
                openContent.Children.Add(current);
            }

            var open = new Button
            {
                Content = openContent,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(10, 8, 8, 8),
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Cursor = Cursors.Hand,
                ToolTip = L10n.T("打开此对话", "Open this chat")
            };
            open.Click += (_, _) =>
            {
                CrossfadeConversationArea();
                SaveConversation();
                DetachTurnViews();
                if (_turn is not null && _turn.Conv.ConvId == id)
                {
                    // 打开的是运行中任务的会话：复用在途状态。
                    _conv = _turn.Conv;
                    RenderHistory();
                    AttachTurnViews();
                }
                else
                {
                    try
                    {
                        var selected = JsonNode.Parse(File.ReadAllText(Path.Combine(ConvDir, id + ".json")))!.AsObject();
                        _conv = new Conversation { Binding = NormalizeStoredBinding((string?)selected["binding"]) };
                        LoadConversationDoc(id, selected);
                    }
                    catch { }
                }
                UpdateSendUi();
                ExitHistoryPage();
            };

            var delete = new Button
            {
                Content = "\uE74D",
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 11,
                Width = 30,
                Height = 30,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Cursor = Cursors.Hand,
                ToolTip = L10n.T("删除此对话", "Delete this chat")
            };
            delete.Click += (_, _) =>
            {
                try { File.Delete(Path.Combine(ConvDir, id + ".json")); } catch { }
                if (_turn?.Conv.ConvId == id) _cts?.Cancel();   // 会话被删，任务一并停止
                if (_conv.ConvId == id)
                {
                    DetachTurnViews();
                    _conv = new Conversation { Binding = _conv.Binding };
                    ChatList.Children.Clear();
                }
                PopulateHistoryList();
                UpdateSendUi();
            };

            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(open);
            Grid.SetColumn(delete, 1);
            row.Children.Add(delete);
            HistoryList.Children.Add(row);
            HistoryList.Children.Add(new Border
            {
                Height = 1,
                Margin = new Thickness(10, 0, 0, 0),
                Background = new SolidColorBrush(Color.FromArgb(22, 0, 0, 0))
            });
        }
    }

    private static string RelativeHistoryDate(DateTime value)
    {
        if (value == DateTime.MinValue) return "";
        var elapsed = DateTime.Now - value.ToLocalTime();
        if (elapsed < TimeSpan.FromMinutes(1)) return L10n.T("刚刚", "Just now");
        if (elapsed < TimeSpan.FromHours(1))
            return L10n.T($"{Math.Max(1, (int)elapsed.TotalMinutes)} 分钟前", $"{Math.Max(1, (int)elapsed.TotalMinutes)}m ago");
        if (elapsed < TimeSpan.FromDays(1))
            return L10n.T($"{Math.Max(1, (int)elapsed.TotalHours)} 小时前", $"{Math.Max(1, (int)elapsed.TotalHours)}h ago");
        if (elapsed < TimeSpan.FromDays(7))
            return L10n.T($"{Math.Max(1, (int)elapsed.TotalDays)} 天前", $"{Math.Max(1, (int)elapsed.TotalDays)}d ago");
        return value.ToLocalTime().ToString("yyyy-MM-dd");
    }

    /// <summary>解析 ```create-file:路径``` 块 → 文本段 + 创建按钮卡（含路径穿越防护）。</summary>
    private void RenderAssistantMessage(string text)
    {
        var re = new System.Text.RegularExpressions.Regex(
            "```create-file:([^\r\n]+)\r?\n(.*?)```",
            System.Text.RegularExpressions.RegexOptions.Singleline);
        var last = 0;
        foreach (System.Text.RegularExpressions.Match m in re.Matches(text))
        {
            var before = text[last..m.Index].Trim();
            if (before.Length > 0) AppendBubble(before, isUser: false);
            AddFileCard(m.Groups[1].Value.Trim(), m.Groups[2].Value);
            last = m.Index + m.Length;
        }
        var rest = text[last..].Trim();
        if (rest.Length > 0 || last == 0) AppendBubble(rest.Length > 0 ? rest : text, isUser: false);
    }

    private void AddFileCard(string relPath, string content)
    {
        var stack = new StackPanel { Margin = new Thickness(4) };
        stack.Children.Add(new SelectableText { Text = "\ud83d\udcc4 " + relPath, FontWeight = FontWeights.SemiBold, FontSize = 12 });
        var status = new SelectableText { FontSize = 11, Foreground = System.Windows.Media.Brushes.Gray };
        var root = _fileTools.Root;
        string? target = null;
        if (root is not null)
        {
            var full = Path.GetFullPath(Path.Combine(root, relPath));
            var rootFull = Path.GetFullPath(root);
            if (full == rootFull || full.StartsWith(rootFull + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
                target = full;
        }
        var exists = target is not null && File.Exists(target);
        var create = new Button
        {
            Content = exists ? L10n.T("覆盖", "Overwrite") : L10n.T("创建", "Create"),
            Width = 70, HorizontalAlignment = HorizontalAlignment.Right
        };
        create.Click += (_, _) =>
        {
            if (target is null) { status.Text = root is null ? L10n.T("未绑定文件夹", "No folder bound") : L10n.T("文件名不合法", "Invalid file name"); return; }
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.WriteAllText(target, content, new System.Text.UTF8Encoding(false));
                status.Text = L10n.T("已创建 \u2713", "Created \u2713");
            }
            catch (Exception ex) { status.Text = L10n.T($"失败：{ex.Message}", $"Failed: {ex.Message}"); }
        };
        stack.Children.Add(new SelectableText
        {
            Text = content.Length > 400 ? content[..400] + "\n…" : content,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 11,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 6)
        });
        stack.Children.Add(create);
        stack.Children.Add(status);
        ChatList.Children.Add(new Border
        {
            Child = stack,
            Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(14, 0, 103, 192)),
            BorderBrush = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(60, 0, 103, 192)),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8), Margin = new Thickness(0, 4, 0, 4), MaxWidth = 300,
            HorizontalAlignment = HorizontalAlignment.Left
        });
    }

    /// <summary>设置保存后刷新窄轨与空状态里的 logo。</summary>
    private void ApplyLogo()
    {
        RailLogo.Source = BrandAssets.Logo(_settings.LogoChoice);
        UpdateEmptyState();
    }

    private FrameworkElement? _emptyState;

    /// <summary>空状态（对齐 mac EmptyStateView）。</summary>
    private void UpdateEmptyState()
    {
        RemoveEmptyState();
        if (!_showingHistory && _conv.History.Count == 0 && ChatList.Children.Count == 0)
        {
            var logo = new System.Windows.Controls.Image
            {
                Source = BrandAssets.Logo(_settings.LogoChoice),
                Width = 96,
                Height = 96,
                Stretch = System.Windows.Media.Stretch.Uniform,
                HorizontalAlignment = HorizontalAlignment.Center,
                // 自定义/Clippy 多为不透明方图，轻裁圆角；默认透明 logo 不受影响。
                Clip = new System.Windows.Media.RectangleGeometry(new Rect(0, 0, 96, 96), 17, 17)
            };
            var message = new SelectableText
            {
                Text = L10n.T("在资源管理器中选中文件/文件夹\n描述你想要的操作",
                              "Select files or folders in Explorer,\nthen describe the operation you want"),
                Foreground = System.Windows.Media.Brushes.Gray,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                FontSize = 12
            };
            var exampleParagraph = new System.Windows.Documents.Paragraph
            {
                TextAlignment = TextAlignment.Center,
                Margin = new Thickness(0)
            };
            var link = new System.Windows.Documents.Hyperlink(
                new System.Windows.Documents.Run(L10n.T("查看示例操作 >", "View example operations >")))
            {
                NavigateUri = new Uri("https://folderis.app/skills")
            };
            link.RequestNavigate += (_, e) =>
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(e.Uri.AbsoluteUri)
                { UseShellExecute = true });
                e.Handled = true;
            };
            exampleParagraph.Inlines.Add(link);
            var examples = new RichTextBox
            {
                Document = new System.Windows.Documents.FlowDocument(exampleParagraph)
                {
                    PagePadding = new Thickness(0),
                    FontSize = 11
                },
                IsReadOnly = true,
                IsDocumentEnabled = true,
                BorderThickness = new Thickness(0),
                Background = System.Windows.Media.Brushes.Transparent,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Margin = new Thickness(0, 8, 0, 0),
                Padding = new Thickness(0),
                Height = 24,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled
            };
            var emptyContent = new StackPanel
            {
                Width = 300,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Children = { logo, message, examples }
            };
            _emptyState = new Viewbox
            {
                Stretch = System.Windows.Media.Stretch.Uniform,
                StretchDirection = StretchDirection.DownOnly,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = emptyContent
            };
            EmptyStateHost.Content = _emptyState;
            EmptyStateHost.Visibility = Visibility.Visible;
        }
    }

    private void RemoveEmptyState()
    {
        if (_emptyState is not null)
        {
            EmptyStateHost.Content = null;
            EmptyStateHost.Visibility = Visibility.Collapsed;
            _emptyState = null;
        }
    }

    private async Task SendAsync()
    {
        var text = InputBox.Text.Trim();
        if (text.Length == 0) return;
        var taskId = NextTaskId();
        var referencedTask = ReferencedTaskContext(text);
        RegisterTask(taskId, text);
        InputBox.Clear();
        RemoveEmptyState();
        AppendBubble(text, isUser: true, taskId: taskId);
        // 捕获会话与工作目录快照：此后面板显示切到哪个绑定都不影响本任务，
        // 任务的输出与落盘始终归属它启动时的会话。
        var conv = _conv;
        var workRoot = _context?.FolderPath;
        var selectedFiles = _attached.ToArray();

        var pureConversation = IsPureConversation(text);
        var fileContext = !pureConversation && _attached.Count > 0
            ? "以下是用户选中/附上的文件，它们就是本次任务的全部输入范围。" +
              "任务描述没有点名对象时，对象就是这些文件，而不是所在文件夹；" +
              "除非用户明确要求，绝不能把操作扩大到范围之外的其他文件，即使它们相似或适用同样的操作：\n" +
              string.Join("\n", _attached) // 模型侧文案，无需双语
            : null;
        string? contextBlock = string.Join("\n\n", new[] { fileContext, referencedTask }
            .Where(s => !string.IsNullOrWhiteSpace(s)));
        if (contextBlock.Length == 0) contextBlock = null;
        var apiText = contextBlock is null ? text : contextBlock + "\n\n---\n\n" + text;
        conv.History.Add(new JsonObject
        {
            ["role"] = "user", ["content"] = apiText, ["taskId"] = taskId
        });

        if (_settings.Backend == "BuiltinApi" &&
            DeepSeekCapabilityNotice(text, _attached) is { } capabilityNotice)
        {
            AppendBubble(capabilityNotice, isUser: false);
            conv.History.Add(new JsonObject { ["role"] = "assistant", ["content"] = capabilityNotice });
            SaveConversation(conv);
            return;
        }

        if (pureConversation)
        {
            var answer = LocalConversationReply(text);
            AppendBubble(answer, isUser: false);
            conv.History.Add(new JsonObject { ["role"] = "assistant", ["content"] = answer });
            SaveConversation(conv);
            return;
        }

        var turn = new RunningTurn { Conv = conv, WorkRoot = workRoot };
        _turn = turn;
        _turnTypingView = new SelectableText
        {
            Text = L10n.T("思考中…", "Thinking…"),
            Foreground = System.Windows.Media.Brushes.Gray,
            FontSize = 11, Margin = new Thickness(4, 2, 0, 6)
        };
        ChatList.Children.Add(_turnTypingView);
        ChatScroll.ScrollToBottom();
        SetSending(true);
        var stopwatch = Stopwatch.StartNew();
        turn.Stage = L10n.T("识别任务…", "Identifying task…");
        void UpdateStatus()
        {
            turn.ElapsedSeconds = (int)stopwatch.Elapsed.TotalSeconds;
            UpdateTurnStatusText();
        }
        var statusTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        statusTimer.Tick += (_, _) => UpdateStatus();
        statusTimer.Start();
        UpdateStatus();
        var systemPrompt =
            $"""
            你是嵌在 Windows 资源管理器旁的文件与编码助手。工作方式类似 Claude Code：用户当前打开的文件夹就是你的工作目录：{workRoot ?? "（当前未绑定文件夹，文件工具不可用）"}。
            始终使用与用户消息相同的语言回复（Always respond in the same language the user writes in）。

            你的工具（路径一律相对于工作目录）：
            - list_files / search_files：浏览目录、按正则搜内容
            - read_file / edit_file / write_file：读取、精确替换、创建新文件；write_file 遇到同名文件默认自动另存 _2、_3，只有用户明确要求覆盖时才可传 overwrite=true
            - move_file / copy_file / trash_file / make_directory：移动、复制、回收站、建目录
            - run_command：在工作目录执行一条命令（可能需要用户确认）
            - run_skill：运行预置技能脚本（免确认、已验证）。遇到技能目录覆盖的任务时优先用它
            - spawn_subagent：派生子代理处理自包含子任务

            技能目录（run_skill 的 skill 与 args 用法）：
            {SkillRunner.Catalog}

            处理任务的方式：
            - 严格遵守用户指定的对象、页码、数量和输出格式，只做完成请求必需的操作；用户只问一页就只处理该页，绝不能擅自扩展为整个文件或所有页面。
            - 用户消息中列出的“选中/附上的文件”就是本次任务的全部输入范围：任务描述没有点名对象时，对象就是这些文件，而不是所在文件夹；绝不能因为文件夹里其他文件相似、或“批量处理更一致”而扩大到列表之外。
            - 用户只要求查看、读取、分析或回答内容时，直接在聊天中返回结果，不创建文件。转换、压缩、OCR、转写、总结为纪要、差异对比、二维码识别、重命名或去重等动作本身就要求生成可交付文件，聊天文字不能替代产物。
            - 产物的保留、命名、目录去向、覆盖边界与删除/去重安全要求，一律以上方技能目录开头的「全局产物规则」为准；run_skill 传参同样受其约束（--overwrite-original/--in-place 只在用户明确要求覆盖时使用，禁止把 --output 指向输入文件）。
            - 不创建用户没要求的副本、拆分页、逐页图片、全量文本或其他衍生物。工具确需中间文件时只能放系统临时目录，并在结束前清理。
            - 如果目标范围不明确且不同理解会产生不同文件或批量操作，先问一个简短的澄清问题，不要自行选择最大范围。
            - 提取 PDF 文字必须用 pdf-ocr；传入用户指定的 --pages。未要求保存时不要传 --output，也不要先调用 PDF 拆分或转图片技能。
            - 当前内置 API 是纯文本模型，不能查看工具生成的图片画面。不得声称“看到了图片样式”。用户要求高保真复刻 PDF/图片视觉版式，而现有技能不能直接完成时，先如实说明限制并询问是否接受只翻译文字或近似排版；不要把 PDF 转图片当作已经完成视觉检查。
            - 先用 list_files / search_files 定位目标，再 read_file 查看，不要凭空猜测文件内容。
            - 只有用户明确要求修改已有文件时才使用 edit_file 或 write_file 的 overwrite=true；否则一律创建唯一的新文件。修改时先读取，优先 edit_file 精确替换（old_string 须唯一）。
            - 需要运行脚本、git、构建等用 run_command；一次给出完整的一条命令并在 purpose 里说明目的。用户拒绝时尊重决定。
            - 只有用户要求的最终文件确实已经生成且工具返回成功，才能说任务完成。预览图、OCR 文本和临时文件都不算最终产物。完成后用一两句话总结，并明确最终文件名。与文件无关的普通问题正常回答，不必调用工具。
            - 当前消息如果只是身份询问、寒暄或感谢，直接回答，不读取文件、不执行命令、不调用任何技能。

            如果文件工具不可用，可以退而用如下格式输出文件，界面会显示"创建"按钮：
            ```create-file:相对文件名
            文件完整内容
            ```
            """;

        _cts = new CancellationTokenSource();
        try
        {
            {
                turn.Stage = L10n.T("匹配内置技能…", "Matching a built-in skill…");
                UpdateStatus();
                var dispatchArgs = new List<string> { "--request", text, "--files" };
                dispatchArgs.AddRange(selectedFiles);
                var dispatchOutput = await _skills.RunAsync(
                    "local-dispatch", dispatchArgs.ToArray(),
                    workRoot ?? Environment.CurrentDirectory, _cts.Token,
                    stage => Dispatcher.BeginInvoke(() =>
                    {
                        // 匹配成功即把标签换成执行阶段，任务被停止后不再回写。
                        if (!ReferenceEquals(_turn, turn)) return;
                        turn.Stage = stage;
                        UpdateStatus();
                    }));
                if (ParseLocalDispatch(dispatchOutput) is { } local && (bool?)local["matched"] == true)
                {
                    turn.Stage = (string?)local["stage"] ?? L10n.T("本地处理…", "Processing locally…");
                    UpdateStatus();
                    var outputs = (local["outputs"] as JsonArray)?
                        .Select(n => (string?)n)
                        .Where(p => !string.IsNullOrWhiteSpace(p))
                        .Select(p => Path.GetFileName(p!))
                        .ToArray() ?? [];
                    string reply;
                    if ((bool?)local["success"] == true && outputs.Length > 0)
                    {
                        var paths = (local["outputs"] as JsonArray)?
                            .Select(n => (string?)n)
                            .Where(p => !string.IsNullOrWhiteSpace(p))
                            .Select(p => p!)
                            .ToArray() ?? [];
                        reply = BuildLocalSkillReply(
                            (string?)local["skill"] ?? "local",
                            (double?)local["elapsed"] ?? 0,
                            paths,
                            (string?)local["details"]);
                    }
                    else if ((bool?)local["success"] == true
                             && ((string?)local["details"])?.Trim() is { Length: > 0 } info)
                    {
                        // 信息查询类技能（csv-preview/qr-read/hash 检测等）成功但天然
                        // 不产文件：答案在 details 里，不能包装成“未完成”（与 macOS 对齐）。
                        var skill = (string?)local["skill"] ?? "local";
                        var elapsed = (double?)local["elapsed"] ?? 0;
                        reply = L10n.T(
                            $"已通过内置技能完成，没有调用 AI（信息查询，无新文件）。\n技能：{skill} · {elapsed:F2} 秒\n{info}",
                            $"Completed with a built-in skill without calling AI (informational; no new files).\nSkill: {skill} · {elapsed:F2}s\n{info}");
                    }
                    else
                    {
                        var detail = ((string?)local["details"])?.Trim();
                        reply = L10n.T($"内置技能未完成：{(string.IsNullOrEmpty(detail) ? "未知错误" : detail)}",
                                      $"The built-in skill did not complete: {(string.IsNullOrEmpty(detail) ? "unknown error" : detail)}");
                    }
                    SetTurnReply(turn, reply);
                    conv.History.Add(new JsonObject { ["role"] = "assistant", ["content"] = reply });
                    if (_settings.Backend != "BuiltinApi")
                        conv.Sessions.Remove(_settings.Backend);
                    SaveConversation(conv);
                    return;
                }
            }
            if (_settings.Backend != "BuiltinApi")
            {
                var kind = _settings.Backend switch
                {
                    "Codex" => BackendKind.Codex,
                    "Cursor" => BackendKind.Cursor,
                    _ => BackendKind.ClaudeCode
                };
                var cli = kind switch
                {
                    BackendKind.Codex => CliBackend.DetectPath("codex"),
                    BackendKind.Cursor => CliBackend.DetectCursorPath(),
                    _ => CliBackend.DetectPath("claude")
                }
                    ?? throw new InvalidOperationException(L10n.T($"未检测到 {_settings.Backend} CLI", $"{_settings.Backend} CLI not found"));
                // 单一来源 fail-safe：产物政策只经 catalog（技能简报）送达 CLI。
                // 加载不到完整政策段时拒绝执行，绝不无政策裸跑文件任务。
                if (string.IsNullOrEmpty(SkillRunner.CliSkillsBrief) || SkillRunner.SharedArtifactPolicy is null)
                    throw new InvalidOperationException(L10n.T(
                        "技能运行时损坏或缺失（无法加载「全局产物规则」），文件处理已停用。请重新安装应用或修复技能组件。",
                        "The skills runtime is missing or corrupted (global artifact policy unavailable), so file processing is disabled. Reinstall the app or repair the skills component."));
                // CLI 后端专属增量。产物去向/碰撞/覆盖/删除安全等共享政策不在此重复：
                // 唯一来源是 catalog.txt 的「全局产物规则」段（经技能简报送达，与 macOS cliScopePolicy 对齐）。
                var cliPrompt =
                    "执行边界：严格按用户指定的文件、页码、数量和格式处理，不擅自扩大为全量或批量。" +
                    "用户消息中列出的选中/附上文件就是本次任务的全部输入范围：任务未点名对象时即以这些文件为对象，绝不能因为同文件夹其他文件相似或批量处理更一致而扩大到列表之外。" +
                    "只要求查看或回答内容时直接回复，不创建文件；转换、压缩、OCR、转写、总结为纪要、差异对比、二维码识别、重命名或去重等动作本身就要求生成可交付文件，聊天文字不能替代产物。" +
                    "产物的保留、命名、目录去向、覆盖边界与删除/去重安全要求，一律以技能目录开头的「全局产物规则」为准；用户指定输出名不等于允许覆盖。" +
                    "不得创建未要求的副本、拆分页、逐页图片或全量文本；必要中间文件必须放在 %TEMP%，不得在用户文件夹内创建 tmp 或 output 工作目录，并在结束前清理，最终多产物 Output 不属于临时目录。" +
                    "范围歧义会导致不同产物时先简短询问。提取 PDF 文字必须逐页 OCR，且只 OCR 用户指定页码。" +
                    "不要把计划、准备步骤或我先做什么当作最终回复；必须实际完成任务并验证最终文件后再结束，无法完成时明确说明失败原因。" +
                    "回复必须精简并明确列出最终文件或 Output 完整路径。\n\n" +
                    $"任务编号：{taskId}\n用户请求：\n" + apiText;
                var completedSessionId = await _cliBackend.RunAsync(
                    kind, cli, cliPrompt, workRoot ?? Environment.CurrentDirectory,
                    yolo: _settings.ApprovalMode == "yolo",
                    sessions: conv.Sessions,
                    onDelta: d => Dispatcher.Invoke(() => AppendTurnReply(turn, d)),
                    onActivity: a => Dispatcher.Invoke(() =>
                    {
                        turn.Stage = a;
                        UpdateStatus();
                        if (ViewingTurn && _turnTypingView is not null &&
                            !ChatList.Children.Contains(_turnTypingView))
                            ChatList.Children.Add(_turnTypingView);
                        if (ViewingTurn) ChatScroll.ScrollToBottom();
                    }),
                    _cts.Token);
                if (!string.IsNullOrWhiteSpace(completedSessionId))
                    conv.Sessions[kind.ToString()] = completedSessionId;
                conv.History.Add(new JsonObject { ["role"] = "assistant", ["content"] = turn.Reply.ToString() });
                SaveConversation(conv);
                return;
            }
            // 单一来源 fail-safe：内置代理循环的产物政策同样只来自 catalog
            // （system prompt 整段注入）。政策缺失即拒绝，避免无政策裸跑。
            if (SkillRunner.SharedArtifactPolicy is null)
                throw new InvalidOperationException(L10n.T(
                    "技能运行时损坏或缺失（无法加载「全局产物规则」），文件处理已停用。请重新安装应用或修复技能组件。",
                    "The skills runtime is missing or corrupted (global artifact policy unavailable), so file processing is disabled. Reinstall the app or repair the skills component."));
            await _agent.CompactIfNeededAsync(conv.History, _cts.Token);
            await _agent.RunAsync(
                conv.History, systemPrompt,
                onDelta: d => Dispatcher.Invoke(() => AppendTurnReply(turn, d)),
                onActivity: a => Dispatcher.Invoke(() =>
                {
                    turn.Stage = a;
                    UpdateStatus();
                    if (ViewingTurn && _turnTypingView is not null &&
                        !ChatList.Children.Contains(_turnTypingView))
                        ChatList.Children.Add(_turnTypingView);
                    if (ViewingTurn) ChatScroll.ScrollToBottom();
                }),
                _cts.Token,
                allowTools: !pureConversation,
                taskId: taskId);
            var finalText = turn.Reply.ToString();
            if (string.IsNullOrWhiteSpace(finalText))
            {
                finalText = L10n.T("处理已完成。", "Done.");
                SetTurnReply(turn, finalText);
            }
            conv.History.Add(new JsonObject { ["role"] = "assistant", ["content"] = finalText });
            SaveConversation(conv);
            if (finalText.Contains("```create-file:") && ViewingTurn && _turnReplyView is not null)
            {
                for (var k = ChatList.Children.Count - 1; k >= 0; k--)
                {
                    if (ChatList.Children[k] is Border b && ReferenceEquals(b.Child, _turnReplyView))
                    { ChatList.Children.RemoveAt(k); break; }
                }
                RenderAssistantMessage(finalText);
            }
        }
        catch (Exception ex)
        {
            var marker = ex is OperationCanceledException
                ? L10n.T("\n（已停止）", "\n(stopped)")
                : "\n❌ " + ex.Message;
            AppendTurnReply(turn, marker);
            // 后台被停止/失败同样落盘：切回该会话时能看到结果与原因。
            conv.History.Add(new JsonObject { ["role"] = "assistant", ["content"] = turn.Reply.ToString() });
            SaveConversation(conv);
        }
        finally
        {
            statusTimer.Stop();
            if (_turnTypingView is not null) ChatList.Children.Remove(_turnTypingView);
            if (turn.PendingApprovalCard is { } card) ChatList.Children.Remove(card);
            _turn = null;
            DetachTurnViews();
            SetSending(false);
            if (ReferenceEquals(conv, _conv)) ChatScroll.ScrollToBottom();
        }
    }

    /// <summary>B8（20260805.3 case61）：完成卡片必须透出技能自身的完成文案（ok() 输出，
    /// 例如 zip-encrypt 的「AES-256；需用 7-Zip 等支持 AES 的工具解压」）。
    /// details 已由 local-dispatch 截到末尾 2000 字符，这里全文展示不再截断（与 macOS 对齐）。</summary>
    internal static string BuildLocalSkillReply(
        string skill, double elapsed, string[] paths, string? details)
    {
        var reply = L10n.T(
            $"已通过内置技能完成，没有调用 AI，也没有覆盖原文件。\n技能：{skill} · {elapsed:F2} 秒\n结果文件：\n{string.Join("\n", paths)}",
            $"Completed with a built-in skill without calling AI or overwriting the originals.\nSkill: {skill} · {elapsed:F2}s\nOutput:\n{string.Join("\n", paths)}");
        var notes = details?.Trim();
        if (!string.IsNullOrEmpty(notes))
            reply += L10n.T($"\n技能说明：\n{notes}", $"\nSkill notes:\n{notes}");
        return reply;
    }

    private static JsonObject? ParseLocalDispatch(string output)
    {
        const string marker = "__FOLDERIS_LOCAL_RESULT__";
        var index = output.LastIndexOf(marker, StringComparison.Ordinal);
        if (index < 0) return null;
        try
        {
            var payload = output[(index + marker.Length)..];
            var lineEnd = payload.IndexOfAny(['\r', '\n']);
            if (lineEnd >= 0) payload = payload[..lineEnd];
            return JsonNode.Parse(payload.Trim()) as JsonObject;
        }
        catch { return null; }
    }

    private static string? DeepSeekCapabilityNotice(string request, IReadOnlyCollection<string> files)
    {
        var text = request.ToLowerInvariant();
        var extensions = files.Select(Path.GetExtension)
            .Select(ext => (ext ?? string.Empty).TrimStart('.').ToLowerInvariant())
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var hasPdf = extensions.Contains("pdf");
        var hasImage = extensions.Overlaps([
            "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"
        ]);
        var hasVideo = extensions.Overlaps(["mp4", "mov", "mkv", "avi", "webm", "m4v"]);

        bool ContainsAny(params string[] terms) =>
            terms.Any(term => text.Contains(term, StringComparison.OrdinalIgnoreCase));

        var acceptedDowngrade = ContainsAny(
            "只翻译文字", "仅翻译文字", "接受近似", "近似排版", "不需要保持", "不用保持",
            "不要求一致", "无需一致", "text only", "approximate layout");
        var requestsTranslation = ContainsAny("翻译", "translate");
        var requestsVisualFidelity = ContainsAny(
            "样式一致", "风格一致", "保持样式", "保留样式", "保持版式", "保留版式",
            "保持排版", "保留排版", "原pdf一致", "完全一致", "高保真",
            "same style", "preserve layout", "keep the layout", "pixel-perfect");
        if (hasPdf && requestsTranslation && requestsVisualFidelity && !acceptedDowngrade)
        {
            return L10n.T(
                "当前使用的是 DeepSeek API。它不能查看 PDF 页面的视觉画面，Folderis 目前无法可靠完成“翻译内容并保持原 PDF 版式一致”，所以我没有开始处理，也不会生成页面图片。\n\n你可以改为：\n1. 只提取并翻译指定页文字；\n2. 生成近似排版的新 PDF，但不保证与原版一致；\n3. 切换 Claude Code、Codex 或 Cursor 后再尝试。",
                "The current DeepSeek API cannot inspect PDF page visuals, so Folderis cannot reliably translate content while preserving the original layout. Nothing was processed. You can request text-only translation, approximate layout, or switch to Claude Code, Codex, or Cursor.");
        }

        var requestsVisualInspection = ContainsAny(
            "描述画面", "分析画面", "查看样式", "看看样式", "视觉比较", "比较外观",
            "图里是什么", "图片里是什么", "什么风格", "分析配色", "看图回答",
            "describe the image", "analyze the image", "visual comparison", "what is in the image");
        if ((hasImage || hasPdf || hasVideo) && requestsVisualInspection)
            return L10n.T(
                "当前使用的是 DeepSeek API，它不能直接查看图片、PDF 页面或视频画面，因此我无法可靠完成这项视觉理解任务，也没有开始创建文件。OCR 文字提取、格式转换、压缩、裁剪等不需要理解画面的操作仍然可以完成。",
                "The current DeepSeek API cannot directly inspect images, PDF pages, or video frames, so this visual-understanding request cannot be completed reliably. No files were created. OCR, conversion, compression, and cropping remain supported.");

        var requestsImageGeneration = ContainsAny(
            "生成图片", "生成一张图", "画一张", "绘制图片", "生成插画", "设计海报",
            "生成logo", "生成 logo", "做一个logo", "做一个 logo",
            "generate an image", "create an illustration", "design a poster", "generate a logo");
        if (requestsImageGeneration)
            return L10n.T(
                "当前 DeepSeek API 和 Folderis 的内置工具不具备图片生成能力，因此我不能完成这项任务，也不会创建占位图片。图片压缩、转换、改尺寸、裁剪、加水印、抠图和 OCR 仍然可用。",
                "The current DeepSeek API and Folderis tools do not support image generation, so this request cannot be completed and no placeholder image will be created. Compression, conversion, resizing, cropping, watermarking, background removal, and OCR remain available.");

        return null;
    }

    private static bool IsPureConversation(string text)
    {
        var normalized = text.Trim().ToLowerInvariant()
            .Trim('。', '！', '？', '!', '?', '.', ',', '，');
        string[] exact =
        [
            "你是谁", "你叫什么", "介绍一下你自己", "你能做什么", "你好", "您好",
            "谢谢", "感谢", "hi", "hello", "who are you", "what are you",
            "what can you do", "thanks", "thank you"
        ];
        return exact.Contains(normalized);
    }

    private static string LocalConversationReply(string text)
    {
        var normalized = text.Trim().ToLowerInvariant();
        if (normalized.Contains("你是谁") || normalized.Contains("你叫什么") ||
            normalized.Contains("who are you") || normalized.Contains("what are you"))
            return L10n.T(
                "我是 Folderis，一个贴靠在文件资源管理器旁的文件操作助手。你可以选中文件，然后直接描述想执行的操作。",
                "I'm Folderis, a file assistant docked beside File Explorer. Select files and describe the operation you want.");
        if (normalized.Contains("能做什么") || normalized.Contains("what can you do"))
            return L10n.T(
                "我可以处理压缩、转换、比较、整理和批量操作等常见任务。更多示例：https://folderis.app/skills",
                "I can handle common compression, conversion, comparison, organization, and batch tasks. Examples: https://folderis.app/skills");
        if (normalized.Contains("谢谢") || normalized.Contains("感谢") ||
            normalized.Contains("thank"))
            return L10n.T("不客气。", "You're welcome.");
        return L10n.T("你好，我是 Folderis。选中文件后，直接描述你想执行的操作即可。",
                      "Hello, I'm Folderis. Select files, then describe the operation you want.");
    }

    private SelectableText AppendBubble(string text, bool isUser, string? taskId = null)
    {
        var tb = new SelectableText
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            Padding = new Thickness(12, 8, 12, 8),
            Foreground = isUser ? Brushes.White : Brushes.Black
        };
        var border = new Border
        {
            Child = tb,
            CornerRadius = new CornerRadius(8),
            Background = isUser
                ? new SolidColorBrush(Color.FromRgb(0, 122, 255))
                : new SolidColorBrush(Color.FromRgb(233, 233, 235)),
            HorizontalAlignment = isUser ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            Margin = new Thickness(0, 4, 0, 4),
            MaxWidth = 280
        };
        if (isUser && !string.IsNullOrWhiteSpace(taskId))
        {
            // 点击复制任务编号 + 短暂提示怎么引用（对齐 mac TaskIDChip）。
            var copiedTip = new TextBlock
            {
                Text = L10n.T("已复制 · 在任意对话输入该编号即可引用此任务",
                              "Copied — type it in any chat to reference this task"),
                FontSize = 9,
                Foreground = Brushes.Gray,
                Margin = new Thickness(0, 0, 6, 1),
                VerticalAlignment = VerticalAlignment.Center,
                Visibility = Visibility.Collapsed
            };
            var label = new TextBlock
            {
                Text = taskId,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 9,
                Foreground = Brushes.Gray,
                Cursor = Cursors.Hand,
                ToolTip = L10n.T("点击复制任务编号", "Click to copy the task ID"),
                Margin = new Thickness(0, 0, 2, 1)
            };
            System.Windows.Threading.DispatcherTimer? hideTipTimer = null;
            label.MouseLeftButtonUp += (_, _) =>
            {
                try { Clipboard.SetText(taskId); }
                catch (System.Runtime.InteropServices.COMException) { return; }   // 剪贴板被其他进程占用
                copiedTip.Visibility = Visibility.Visible;
                hideTipTimer?.Stop();
                hideTipTimer = new System.Windows.Threading.DispatcherTimer
                {
                    Interval = TimeSpan.FromSeconds(2.5)
                };
                hideTipTimer.Tick += (_, _) =>
                {
                    copiedTip.Visibility = Visibility.Collapsed;
                    hideTipTimer.Stop();
                };
                hideTipTimer.Start();
            };
            var idRow = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            idRow.Children.Add(copiedTip);
            idRow.Children.Add(label);
            var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
            stack.Children.Add(idRow);
            stack.Children.Add(border);
            ChatList.Children.Add(stack);
        }
        else
        {
            ChatList.Children.Add(border);
        }
        ChatScroll.ScrollToBottom();
        return tb;
    }
}
