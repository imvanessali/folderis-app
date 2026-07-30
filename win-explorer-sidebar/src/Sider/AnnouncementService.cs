using System.IO;
using System.Net.Http;
using System.Text.Json;

namespace Sider;

/// <summary>
/// 版本公告（轻量更新提示）：启动后静默拉取 announce.json，发现比本机新的
/// 版本就把状态抛给面板横幅「前往下载」，点击打开发布页网页。不下载、
/// 不安装、无签名验签——下发内容完全由发布者改 JSON 控制，撤回即恢复安静。
/// 「稍后」在该版本内不再提醒（记 announce.dismissed 文件，跨重启生效）。
/// 与 macOS 端 AnnouncementManager 同一套约定与 JSON 格式。
/// </summary>
public sealed class AnnouncementService
{
    /// <summary>公告地址：Cloudflare Worker 静态托管，FOLDERIS_ANNOUNCE_URL 可覆盖（测试用）。</summary>
    public const string DefaultFeed = "https://folderis-announce.folderis.workers.dev/announce.json";

    private static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);

    private readonly object _logLock = new();
    private System.Threading.SynchronizationContext? _ui;
    private bool _started;

    /// <summary>公告状态变化（已切回 UI 线程）。</summary>
    public event Action? StateChanged;

    /// <summary>有比本机新、且用户没点过「稍后」的版本待提示。</summary>
    public bool HasNotice => Version is not null && PageUrl is not null;

    public string? Version { get; private set; }
    public string? PageUrl { get; private set; }
    /// <summary>发布者自定义文案（announce.json 的 message.zh/en），空则用默认文案。</summary>
    public string? Message { get; private set; }

    private static string DismissPath => Path.Combine(SkillRunner.SupportRoot, "announce.dismissed");

    /// <summary>在 UI 线程调用：记住 SynchronizationContext 好把状态变化抛回来。</summary>
    public void Start()
    {
        if (_started) return;
        _started = true;
        _ui = System.Threading.SynchronizationContext.Current;
        _ = RunLoopAsync();
    }

    /// <summary>用户点「前往下载」：用默认浏览器打开发布页。</summary>
    public void OpenDownloadPage()
    {
        if (PageUrl is null) return;
        try
        {
            System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo(PageUrl) { UseShellExecute = true });
        }
        catch (Exception ex) { Log("打开下载页失败：" + ex.Message); }
    }

    /// <summary>「稍后」：本版本内（含重启）不再提醒；下发更新的版本号后重新亮起。</summary>
    public void Dismiss()
    {
        if (Version is null) return;
        try { File.WriteAllText(DismissPath, Version); }
        catch (Exception ex) { Log("记录稍后失败：" + ex.Message); }
        Version = null; PageUrl = null; Message = null;
        StateChanged?.Invoke();
    }

    private async Task RunLoopAsync()
    {
        try
        {
            await Task.Delay(StartupDelay);
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            while (true)
            {
                await CheckOnceAsync(http);
                await Task.Delay(CheckInterval);
            }
        }
        catch (Exception ex)
        {
            Log("公告循环异常退出：" + ex);
        }
    }

    private async Task CheckOnceAsync(HttpClient http)
    {
        try
        {
            var feed = Environment.GetEnvironmentVariable("FOLDERIS_ANNOUNCE_URL")
                is { Length: > 0 } custom ? custom : DefaultFeed;
            var json = await http.GetStringAsync(feed);
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("win", out var win)) return;
            var version = win.TryGetProperty("version", out var v) ? v.GetString()?.Trim() : null;
            var page = win.TryGetProperty("url", out var u) ? u.GetString()?.Trim() : null;
            if (string.IsNullOrEmpty(version) || page is null ||
                !page.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                return;

            string? message = null;
            if (doc.RootElement.TryGetProperty("message", out var msgs) &&
                msgs.TryGetProperty(L10n.IsChinese ? "zh" : "en", out var m))
                message = m.GetString()?.Trim();

            var dismissed = File.Exists(DismissPath) ? File.ReadAllText(DismissPath).Trim() : "";
            // 与构建号比对(ProductInfo.Build,如 20260727.4)——announce.json 的
            // version 用同一格式;营销版本号(AssemblyVersion 1.1.0)不参与比较。
            // 本地 dev 构建 Build="dev" 按 0 处理,会看到线上公告,便于自测。
            if (!IsNewer(version, ProductInfo.Build) || version == dismissed)
            {
                // 公告被撤回/已是最新/已点过稍后：收起可能还亮着的横幅
                if (HasNotice) { Version = null; PageUrl = null; Message = null; Notify(); }
                return;
            }
            Version = version;
            PageUrl = page;
            Message = string.IsNullOrEmpty(message) ? null : message;
            Log($"发现新版本公告 {version} → {page}");
            Notify();
        }
        catch (Exception ex)
        {
            // 断网、404、JSON 坏了都走这里：静默等下一轮，不打扰用户
            Log("拉取公告失败：" + ex.Message);
        }
    }

    private void Notify()
    {
        if (_ui is not null) _ui.Post(_ => StateChanged?.Invoke(), null);
        else StateChanged?.Invoke();
    }

    /// <summary>按 "." 分段数值比较（20260730.1 > 20260727.4），缺段补零。</summary>
    internal static bool IsNewer(string a, string b)
    {
        var pa = a.Split('.');
        var pb = b.Split('.');
        for (var i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            var x = i < pa.Length && int.TryParse(pa[i], out var xi) ? xi : 0;
            var y = i < pb.Length && int.TryParse(pb[i], out var yi) ? yi : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// <summary>公告日志单独落 announce.log，和 startup.log / error.log 一个目录。</summary>
    private void Log(string message)
    {
        try
        {
            lock (_logLock)
            {
                var dir = SkillRunner.SupportRoot;
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "announce.log"),
                    $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}\n");
            }
        }
        catch { /* 日志失败不影响公告 */ }
    }
}
