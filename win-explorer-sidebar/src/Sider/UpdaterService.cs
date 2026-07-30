using System.IO;
using NetSparkleUpdater;
using NetSparkleUpdater.Enums;
using NetSparkleUpdater.Interfaces;
using NetSparkleUpdater.SignatureVerifiers;

namespace Sider;

/// <summary>
/// 自动更新（无感升级）：后台静默检查 + 静默下载，就绪后只把状态抛给面板横幅，
/// 由用户点“立即重启”才真正安装。全程不弹任何模态对话框——NetSparkle 的
/// 自带界面没有引入（UIFactory 为 null），横幅是面板自研的。
///
/// 与 macOS 端（Sparkle 2）保持同一套约定：
///   appcast   = {FOLDERIS_APPCAST_URL 或 https://dl.folderis.app/win/appcast.xml}
///   签名      = Ed25519，SecurityMode.Strict（appcast 与安装器都必须验签通过）
///   安装      = NSIS 静默模式 /S，装完由 NetSparkle 生成的批处理拉起应用
/// </summary>
public sealed class UpdaterService
{
    /// <summary>
    /// 发布用 Ed25519 公钥（base64，对应 $FOLDERIS_NETSPARKLE_KEYS/NetSparkle_Ed25519.pub）。
    /// 换成真实公钥前保持占位符：占位符状态下更新器整体禁用，
    /// 绝不降级成“不校验签名”。生成方式见 win-explorer-sidebar/README.md。
    /// </summary>
    public const string PublicKey = "OcvVq2hZwRpOOEPqF7KYeWzIsJqKjfjo1F4AnnO29ts=";

    /// <summary>更新分发根地址（与 macOS 端同一个域）。</summary>
    public const string DefaultBaseUrl = "https://dl.folderis.app";

    private static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);

    private readonly object _logLock = new();
    private SparkleUpdater? _sparkle;
    /// <summary>本轮正在下载的条目：DownloadFinished 回调的 item 常为 null，见 OnDownloadFinished。</summary>
    private AppCastItem? _pendingItem;
    private AppCastItem? _readyItem;
    private string? _readyPath;
    private bool _installing;

    /// <summary>下载就绪状态变化（已切回 UI 线程）。</summary>
    public event Action? StateChanged;

    /// <summary>新版本已下载完并验签通过，等用户点“立即重启”。</summary>
    public bool IsReady => _readyItem is not null && _readyPath is not null;

    /// <summary>
    /// 就绪版本号（横幅文案用），未就绪时为 null。取 sparkle:version（完整版本号），
    /// 生成器推导出的 shortVersionString 会丢末段，只作兜底。
    /// </summary>
    public string? ReadyVersion =>
        string.IsNullOrWhiteSpace(_readyItem?.Version) ? _readyItem?.ShortVersion : _readyItem?.Version;

    public static string AppCastUrl =>
        Environment.GetEnvironmentVariable("FOLDERIS_APPCAST_URL") is { Length: > 0 } custom
            ? custom
            : $"{DefaultBaseUrl}/win/appcast.xml";

    /// <summary>
    /// 必须在 UI 线程调用：SparkleUpdater 用构造时的 SynchronizationContext
    /// 把下载完成等事件抛回来，横幅才能直接改界面。
    /// </summary>
    public void Start()
    {
        if (_sparkle is not null) return;

        var key = ResolvePublicKey();
        if (string.IsNullOrEmpty(key))
        {
            Log("Ed25519 公钥仍是占位符，自动更新已禁用（不会降级为不校验签名）。" +
                "发布前需把 UpdaterService.PublicKey 换成真实公钥。");
            return;
        }

        _sparkle = new SparkleUpdater(AppCastUrl, new Ed25519Checker(SecurityMode.Strict, key))
        {
            // 不装 NetSparkleUpdater.UI.*：所有提示都走面板横幅，杜绝模态弹窗
            UIFactory = null,
            LogWriter = new UpdateLogWriter(this),
            // false：事件经 SynchronizationContext 回到 UI 线程再触发
            ShowsUIOnMainThread = false,
            // 静默下载但绝不自动安装，安装时机完全由用户点横幅决定
            UserInteractionMode = UserInteractionMode.DownloadNoInstall,
            // 安装完由 NetSparkle 写的批处理重新拉起 Folderis.exe（安装器自己不负责重启）
            RelaunchAfterUpdate = true,
            // NSIS 静默安装：全程无界面、无向导
            CustomInstallerArguments = "/S",
            // 直接用 appcast 里的文件名，省掉一次探测服务器文件名的请求
            CheckServerFileName = false,
        };
        _sparkle.DownloadFinished += OnDownloadFinished;
        _sparkle.DownloadHadError += (item, path, ex) =>
            Log($"下载失败：{item?.Version} {path} {ex?.Message}");
        _sparkle.DownloadedFileIsCorrupt += (item, path) =>
            Log($"下载的安装包验签失败，已丢弃：{item?.Version} {path}");
        // UIFactory 为 null 时 NetSparkle 不知道怎么退出应用，必须自己接管
        _sparkle.CloseApplication += ShutdownApp;

        Log($"更新器已启动。appcast={AppCastUrl}；当前版本={ProductInfo.Version}");
        _ = RunLoopAsync();
    }

    /// <summary>用户点“立即重启”：装完后由批处理自动拉起新版本。</summary>
    public void InstallAndRestart()
    {
        if (_sparkle is null || _readyItem is null || _readyPath is null || _installing) return;
        _installing = true;
        Log($"用户确认安装 {_readyItem.Version}：{_readyPath} /S");
        // 内部会先等应用退出，再跑 "安装器 /S"，最后重新启动 Folderis.exe
        _sparkle.InstallUpdate(_readyItem, _readyPath);
    }

    private async Task RunLoopAsync()
    {
        try
        {
            await Task.Delay(StartupDelay);
            while (true)
            {
                await CheckOnceAsync();
                await Task.Delay(CheckInterval);
            }
        }
        catch (Exception ex)
        {
            Log("更新循环异常退出：" + ex);
        }
    }

    private async Task CheckOnceAsync()
    {
        if (_sparkle is null || IsReady || _installing) return;
        try
        {
            var info = await _sparkle.CheckForUpdatesQuietly();
            if (info is null || info.Status != UpdateStatus.UpdateAvailable ||
                info.Updates is not { Count: > 0 })
            {
                Log($"检查完成：{info?.Status.ToString() ?? "无返回"}");
                return;
            }
            var item = info.Updates[0];
            Log($"发现新版本 {item.Version}，开始后台下载：{item.DownloadLink}");
            _pendingItem = item;    // 回调里 item 可能是 null，靠这份兜底
            await _sparkle.InitAndBeginDownload(item);
        }
        catch (Exception ex)
        {
            // 断网、appcast 404、验签失败都走这里：静默重试，不打扰用户
            Log("检查更新失败：" + ex.Message);
        }
    }

    /// <summary>
    /// 下载完成（已验签）。参数按可空处理：NetSparkle 2.3.0 是把
    /// DownloadFinished 的调用 Post 到同步上下文后立刻把 _itemBeingDownloaded 置 null，
    /// 回调真正跑起来时读到的就是 null（只有“%TEMP% 里已有同名安装包”那条分支才非 null）。
    /// 这里一律用 _pendingItem 兜底，绝不让空引用冒泡到
    /// DispatcherUnhandledException——那会弹「启动失败」模态框并杀掉进程。
    /// </summary>
    private void OnDownloadFinished(AppCastItem? item, string? path)
    {
        var resolved = item ?? _pendingItem;
        if (resolved is null || string.IsNullOrEmpty(path))
        {
            // 拿不到条目就没法验签安装，放弃本轮，等下一次检查重来
            Log($"下载完成但信息不全（item={(item is null ? "null" : item.Version)}, " +
                $"pending={(_pendingItem is null ? "null" : _pendingItem.Version)}, " +
                $"path={path ?? "null"}），本轮放弃。");
            return;
        }
        _readyItem = resolved;
        _readyPath = path;
        Log($"新版本 {resolved.Version} 已下载并验签通过：{path}");
        StateChanged?.Invoke();
    }

    /// <summary>
    /// 公钥来源：FOLDERIS_NETSPARKLE_PUBKEY 优先（仅供本地起 http server 测试假 appcast，
    /// 会写日志留痕；依然是 Strict 校验，只是换一把公钥），否则用内置常量；
    /// 常量仍是占位符时返回空 → 调用方直接禁用更新器。
    /// </summary>
    private string ResolvePublicKey()
    {
        var overrideKey = Environment.GetEnvironmentVariable("FOLDERIS_NETSPARKLE_PUBKEY");
        if (!string.IsNullOrWhiteSpace(overrideKey))
        {
            Log("注意：FOLDERIS_NETSPARKLE_PUBKEY 覆盖了内置公钥（本地测试用），验签仍为 Strict。");
            return overrideKey.Trim();
        }
        var key = PublicKey;
        return key.StartsWith("REPLACE_WITH", StringComparison.Ordinal) ? "" : key.Trim();
    }

    private static void ShutdownApp()
    {
        var app = System.Windows.Application.Current;
        if (app is null) { Environment.Exit(0); return; }
        if (app.Dispatcher.CheckAccess()) app.Shutdown();
        else app.Dispatcher.BeginInvoke(new Action(() => app.Shutdown()));
    }

    /// <summary>更新日志单独落 update.log，和 startup.log / error.log 一个目录。</summary>
    internal void Log(string message)
    {
        try
        {
            lock (_logLock)
            {
                var dir = SkillRunner.SupportRoot;
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "update.log"),
                    $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}\n");
            }
        }
        catch { /* 日志失败不影响更新 */ }
    }

    /// <summary>把 NetSparkle 内部日志接到同一个 update.log。</summary>
    private sealed class UpdateLogWriter(UpdaterService owner) : ILogger
    {
        public void PrintMessage(string message, params object[] arguments)
        {
            try
            {
                owner.Log("netsparkle: " +
                    (arguments is { Length: > 0 } ? string.Format(message, arguments) : message));
            }
            catch { }
        }
    }
}
