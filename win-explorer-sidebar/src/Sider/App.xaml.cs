using System.IO;
using System.Reflection;
using System.Windows;

namespace Sider;

internal static class ProductInfo
{
    /// <summary>
    /// 版本单一来源：csproj 的 Version（发版时由 build_release.sh 的
    /// FOLDERIS_APP_VERSION 经 -p:Version 注入），运行时直接读程序集，
    /// 与自动更新比对的版本号（NetSparkle 读 AssemblyVersion）是同一个。
    /// </summary>
    public static readonly string Version =
        typeof(ProductInfo).Assembly.GetName().Version?.ToString() ?? "0.0.0.0";
    /// <summary>构建号：由 csproj 的 FolderisBuild 写进 InformationalVersion（Version+构建号）。</summary>
    public static readonly string Build = ReadBuild();
    public const string Name = "Folderis";

    private static string ReadBuild()
    {
        var info = typeof(ProductInfo).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";
        var plus = info.IndexOf('+');
        return plus >= 0 && plus + 1 < info.Length ? info[(plus + 1)..] : "dev";
    }

    public const string Edition = "Full";
    public const string MutexName = "Folderis.Sider.Full.Single";
}

public partial class App : Application
{
    private static void LogStartup(string message)
    {
        try
        {
            var dir = SkillRunner.SupportRoot;
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "startup.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n");
        }
        catch { }
    }

    private static void LogCrash(Exception? ex)
    {
        try
        {
            var dir = SkillRunner.SupportRoot;
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "error.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {ex}\n\n");
        }
        catch { /* 日志失败不再抛 */ }
    }

    private System.Windows.Forms.NotifyIcon? _tray;

    private static System.Threading.Mutex? _single;

    public App()
    {
        LogStartup($"Starting {ProductInfo.Name} {ProductInfo.Version} ({ProductInfo.Build}); " +
                   $"OS={Environment.OSVersion}; process={Environment.ProcessPath}");
        _single = new System.Threading.Mutex(true, ProductInfo.MutexName, out var isNew);
        if (!isNew)
        {
            LogStartup("A second instance was rejected by the single-instance mutex");
            System.Windows.MessageBox.Show(
                $"{ProductInfo.Name} 已在运行（看系统托盘 ^ 展开区）。", ProductInfo.Name,
                System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Information);
            Environment.Exit(0);
        }
        // 尽早挂钩：XAML 解析/静态初始化阶段的崩溃也能捕获
        AppDomain.CurrentDomain.UnhandledException += (_, ev) =>
            FatalExit(ev.ExceptionObject as Exception);
        DispatcherUnhandledException += (_, ev) =>
        {
            FatalExit(ev.Exception);
            ev.Handled = true;
        };
    }

    /// <summary>写日志 + 弹窗后退出：绝不静默死亡。</summary>
    private static void FatalExit(Exception? ex)
    {
        LogStartup("Fatal startup failure: " + ex);
        LogCrash(ex);
        try
        {
            System.Windows.MessageBox.Show(
                $"{ProductInfo.Name} 启动失败：\n\n" + (ex?.Message ?? "未知错误") +
                "\n\n完整日志：%LOCALAPPDATA%\\Sider\\error.log",
                ProductInfo.Name, System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Error);
        }
        catch { }
        Environment.Exit(1);
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        try
        {
            StartupCore(e);
        }
        catch (Exception ex)
        {
            FatalExit(ex);
        }
    }

    private void StartupCore(StartupEventArgs e)
    {
        base.OnStartup(e);
        LogStartup("WPF startup entered");
        LogStartup($"Skills runtime resolved to {SkillRunner.RuntimeRoot}; " +
                   $"skillsVersion={SkillRunner.SkillsVersion}");

        // 首启引导：选择 AI 来源 / 配置 Key（完成前不出面板）。
        var settings = Settings.Load();
        LogStartup($"Settings loaded. onboardingDone={settings.OnboardingDone}; backend={settings.Backend}");
        if (!settings.OnboardingDone)
        {
            LogStartup("Showing onboarding window");
            new OnboardingWindow(settings).ShowDialog();
            LogStartup("Onboarding window closed");
        }

        var panel = new MainPanel();
        MainWindow = panel;
        // 面板由 PanelDocker 控制显隐与位置，不主动 Show。

        SetupTray(panel);
        LogStartup("Main panel handle and tray icon initialized");

        // Folderis has no login-item auto start. Reaching this branch therefore
        // means the user explicitly launched it; always provide visible feedback
        // instead of leaving a tray-only process that looks like a failed launch.
        if (settings.OnboardingDone)
        {
            Dispatcher.BeginInvoke(() =>
            {
                System.Windows.MessageBox.Show(
                    L10n.T(
                        "Folderis 已启动。打开文件资源管理器即可看到跟随窗口的面板，也可以在系统托盘找到 Folderis。",
                        "Folderis is running. Open File Explorer to see the docked panel, or find Folderis in the system tray."),
                    ProductInfo.Name,
                    System.Windows.MessageBoxButton.OK,
                    System.Windows.MessageBoxImage.Information);
            });
        }
    }

    /// <summary>托盘图标：显示/隐藏面板 + 退出（对齐 macOS 菜单栏行为）。</summary>
    private void SetupTray(MainPanel panel)
    {
        // 托盘图标直接取 exe 内嵌的应用图标（ApplicationIcon），不依赖外部文件。
        _tray = new System.Windows.Forms.NotifyIcon
        {
            Icon = (Environment.ProcessPath is string p
                        ? System.Drawing.Icon.ExtractAssociatedIcon(p)
                        : null)
                   ?? System.Drawing.SystemIcons.Application,
            Visible = true,
            Text = ProductInfo.Name
        };
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add(L10n.T("显示/隐藏面板", "Show/Hide Panel"), null,
            (_, _) => panel.Dispatcher.Invoke(panel.ToggleCollapsed));
        menu.Items.Add(L10n.T("清空对话", "Clear Conversation"), null,
            (_, _) => panel.Dispatcher.Invoke(panel.ClearConversation));
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add(L10n.T($"退出 {ProductInfo.Name}", $"Quit {ProductInfo.Name}"), null, (_, _) => Shutdown());
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => panel.Dispatcher.Invoke(panel.ToggleCollapsed);
        _tray.BalloonTipTitle = ProductInfo.Name;
        _tray.BalloonTipText = L10n.T(
            "Folderis 已启动。打开文件资源管理器即可看到面板；也可以双击托盘图标。",
            "Folderis is running. Open File Explorer to see the panel, or double-click the tray icon.");
        _tray.ShowBalloonTip(5000);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_tray is not null) { _tray.Visible = false; _tray.Dispose(); }
        base.OnExit(e);
    }
}
