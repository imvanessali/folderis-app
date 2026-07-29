using System.Windows;
using System.Windows.Media;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Sider;

/// <summary>
/// 把面板窗口贴靠在目标 Explorer 窗口右缘并跟随移动/缩放。
/// 骨架版用 150ms 轮询 GetWindowRect；正式版换 SetWinEventHook
/// (EVENT_OBJECT_LOCATIONCHANGE) 事件驱动。
/// </summary>
public sealed class PanelDocker
{
    public double PanelWidth { get; set; } = 340;
    /// <summary>收起态窄轨宽度（对齐 mac CollapsedRailView.width）。</summary>
    public double CollapsedWidth { get; set; } = 56;

    private readonly Window _panel;
    private readonly ExplorerTracker _tracker;
    private readonly DispatcherTimer _timer;
    private nint _panelHwnd;

    public event Action<ExplorerContext?>? ContextChanged;
    private string? _lastFolder;
    private string _lastSelectionKey = "";

    public PanelDocker(Window panel, ExplorerTracker tracker)
    {
        _panel = panel;
        _tracker = tracker;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _timer.Tick += (_, _) => Tick();
    }

    private bool _collapsed;

    public bool IsCollapsed => _collapsed;

    /// <summary>收起/展开时通知面板切换内部 UI（窄轨 ↔ 完整内容）。</summary>
    public event Action<bool>? CollapsedChanged;

    public void Start()
    {
        _panelHwnd = new WindowInteropHelper(_panel).EnsureHandle();
        NativeMethods.MakeActivatable(_panelHwnd);
        _timer.Start();
    }

    public void Collapse()
    {
        _collapsed = true;
        CollapsedChanged?.Invoke(true);
        Tick();   // 立即按窄宽度重贴，不等下一次轮询
    }

    public void Expand()
    {
        _collapsed = false;
        CollapsedChanged?.Invoke(false);
        Tick();
    }

    public void Stop() => _timer.Stop();

    private static int _diagCount;

    /// <summary>前 60 条状态写 %LOCALAPPDATA%\Sider\debug.log，真机排障用。</summary>
    private static void Diag(string msg)
    {
        if (_diagCount >= 60) return;
        _diagCount++;
        try
        {
            System.IO.File.AppendAllText(
                System.IO.Path.Combine(SkillRunner.SupportRoot, "debug.log"),
                $"[{DateTime.Now:HH:mm:ss.fff}] {msg}\n");
        }
        catch { }
    }

    private void HideAll()
    {
        _panel.Hide();
    }

    private void Tick()
    {
        try
        {
            TickCore();
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException
                                   or System.Runtime.InteropServices.InvalidComObjectException)
        {
            // Explorer is an out-of-process COM server. Closing a tab can invalidate it mid-tick.
            Diag($"transient Explorer COM error: {ex.HResult:X8} {ex.Message}");
        }
        catch (Exception ex)
        {
            // A tracking heartbeat must never take down the whole app.
            Diag($"tracker tick error: {ex.GetType().Name} {ex.Message}");
        }
    }

    private void TickCore()
    {
        var ctx = _tracker.GetFrontmost();
        if (ctx is null || !NativeMethods.IsWindow(ctx.Hwnd))
        {
            Diag(ctx is null ? "no ctx (tracker returned null)" : $"stale hwnd {ctx.Hwnd}");
            HideAll();
            return;
        }
        // 对齐 macOS 版修复：最小化/不可见的窗口不贴（避免面板贴着"看不见的窗口"出现）；
        // 前台既不是目标 Explorer 也不是面板自己时收起（在别的应用里不弹面板）。
        if (!NativeMethods.IsWindowVisible(ctx.Hwnd) || NativeMethods.IsIconic(ctx.Hwnd))
        {
            HideAll();
            return;
        }
        var fg = NativeMethods.GetForegroundWindow();
        // 前台=目标窗口本身、其拥有者链上的窗口、或本进程任意窗口 → 都算"在场"
        var fgRoot = NativeMethods.GetAncestor(fg, NativeMethods.GA_ROOTOWNER);
        NativeMethods.GetWindowThreadProcessId(fg, out var fgPid);
        // 本进程窗口（面板、托盘菜单、设置弹窗）在前台时：只维持已显示的面板，
        // 不唤起隐藏的面板——否则点托盘退出时面板会凭空贴上来（对齐 mac 语义）。
        bool ours = fgPid == Environment.ProcessId && _panel.IsVisible;
        if (fg != ctx.Hwnd && fgRoot != ctx.Hwnd && !ours)
        {
            Diag($"hide: fg={fg} fgRoot={fgRoot} target={ctx.Hwnd} fgPid={fgPid}");
            HideAll();
            return;
        }

        // 目录/选中变化时通知（驱动会话绑定与附件同步）
        var selectionKey = string.Join("|", ctx.SelectedPaths);
        if (ctx.FolderPath != _lastFolder || selectionKey != _lastSelectionKey)
        {
            _lastFolder = ctx.FolderPath;
            _lastSelectionKey = selectionKey;
            ContextChanged?.Invoke(ctx);
        }

        if (!NativeMethods.GetVisibleRect(ctx.Hwnd, out var r)) return;
        Diag($"dock: target={ctx.Hwnd} rect=({r.Left},{r.Top},{r.Right},{r.Bottom}) folder={ctx.FolderPath}");

        // 收起态与展开态走同一条贴靠路径，只是宽度不同：
        // 面板本体缩成窄轨（icon + ">"），仍贴在 Explorer 右缘。
        var dpi = VisualTreeHelper.GetDpi(_panel);
        int widthPx = (int)((_collapsed ? CollapsedWidth : PanelWidth) * dpi.DpiScaleX);

        // 挤压布局（对齐 mac squeeze）：屏幕放不下面板时压窄 Explorer 而不是重叠。
        var work = NativeMethods.GetWorkArea(ctx.Hwnd);
        int minExplorerPx = (int)(480 * dpi.DpiScaleX);
        int overflow = (r.Right + widthPx) - work.Right;
        if (overflow > 2)
        {
            if (NativeMethods.IsZoomed(ctx.Hwnd))
            {
                NativeMethods.ShowWindow(ctx.Hwnd, NativeMethods.SW_RESTORE);
                // 还原后按工作区满高铺（视觉上仍像最大化，只是让出面板位）
                NativeMethods.SetWindowPos(ctx.Hwnd, 0,
                    work.Left, work.Top,
                    Math.Max(minExplorerPx, work.Right - work.Left - widthPx),
                    work.Bottom - work.Top, NativeMethods.SWP_NOACTIVATE);
            }
            else
            {
                int newW = Math.Max(minExplorerPx, r.Right - r.Left - overflow);
                int newX = r.Left;
                if (newX + newW + widthPx > work.Right)
                    newX = Math.Max(work.Left, work.Right - widthPx - newW);
                NativeMethods.SetWindowPos(ctx.Hwnd, 0,
                    newX, r.Top, newW, r.Bottom - r.Top, NativeMethods.SWP_NOACTIVATE);
            }
            if (!NativeMethods.GetVisibleRect(ctx.Hwnd, out r)) return;
        }

        NativeMethods.SetWindowPos(
            _panelHwnd, NativeMethods.HWND_TOPMOST,
            r.Right, r.Top, widthPx, r.Bottom - r.Top,
            NativeMethods.SWP_NOACTIVATE);

        if (!_panel.IsVisible) _panel.Show();
    }
}
