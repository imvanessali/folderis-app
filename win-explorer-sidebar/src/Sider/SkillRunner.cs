using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Sider;

/// <summary>
/// 技能执行器：与 macOS 版共用同一个 skills.py 工具箱（纯 Python，跨平台）。
/// 正式安装优先使用 EXE 同目录的 runtime；仅在它不完整时才回退
/// %LOCALAPPDATA%\Sider。测试和诊断必须读取 RuntimeRoot，不能写死兜底路径。
/// </summary>
public sealed class SkillRunner
{
    private static readonly string ResolvedSupportRoot = InitializeSupportRoot();

    public static string SupportRoot => ResolvedSupportRoot;

    private static string InitializeSupportRoot()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var current = Path.Combine(local, "Sider");
        var legacy = Path.Combine(local, "ExplorerSidebar");
        if (!Directory.Exists(current) && Directory.Exists(legacy))
        {
            try { Directory.Move(legacy, current); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        Directory.CreateDirectory(current);
        return current;
    }

    private static string BundledRuntimeRoot => Path.Combine(AppContext.BaseDirectory, "runtime");
    private static string ActiveRuntimeRoot => HasRuntime(BundledRuntimeRoot)
        ? BundledRuntimeRoot
        : SupportRoot;
    public static string RuntimeRoot => ActiveRuntimeRoot;
    public static string SkillsVersion => ReadSkillsVersion(ActiveRuntimeRoot);
    private static string PythonExe => Path.Combine(ActiveRuntimeRoot, "python", "python.exe");
    private static string Toolbox => Path.Combine(ActiveRuntimeRoot, "skills", "skills.py");

    private static bool HasRuntime(string root)
    {
        var marker = ReadSkillsVersion(root);
        return File.Exists(Path.Combine(root, "python", "python.exe")) &&
               File.Exists(Path.Combine(root, "skills", "skills.py")) &&
               File.Exists(Path.Combine(root, "skills", "catalog.txt")) &&
               marker != "missing" &&
               string.Equals(marker, ComputeSkillsVersion(root), StringComparison.OrdinalIgnoreCase);
    }

    private static string ReadSkillsVersion(string root)
    {
        var marker = Path.Combine(root, "SKILLS_VERSION");
        return File.Exists(marker) ? File.ReadAllText(marker).Trim() : "missing";
    }

    private static string ComputeSkillsVersion(string root)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var name in new[] { "catalog.txt", "skills.py" })
        {
            var path = Path.Combine(root, "skills", name);
            if (!File.Exists(path)) return "missing";
            hash.AppendData(Encoding.UTF8.GetBytes(name + "\0"));
            hash.AppendData(File.ReadAllBytes(path));
        }
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    public static string Catalog => LoadCatalog();

    private static string LoadCatalog()
    {
        var p = Path.Combine(ActiveRuntimeRoot, "skills", "catalog.txt");
        return File.Exists(p) ? File.ReadAllText(p) : "";
    }

    /// <summary>共享产物政策的唯一来源标记（与 macOS 端 artifactPolicyMarker 对齐）：
    /// catalog.txt 中以该标记开头的整段。按标记提取而非物理行号。</summary>
    public const string ArtifactPolicyMarker = "全局产物规则：";

    /// <summary>null 意味着技能运行时损坏——按约定拒绝文件处理而不是无政策裸跑。</summary>
    public static string? SharedArtifactPolicy => ExtractArtifactPolicy(Catalog);

    public static string? ExtractArtifactPolicy(string catalog)
    {
        var index = catalog.IndexOf(ArtifactPolicyMarker, StringComparison.Ordinal);
        if (index < 0) return null;
        var end = catalog.IndexOf('\n', index);
        var policy = (end < 0 ? catalog[index..] : catalog[index..end]).Trim();
        // 语义完整性下限：防止截断/损坏的 catalog 提供半句政策。
        string[] required = ["原文件", "Output", "覆盖", "副本"];
        if (policy.Length <= 80 || required.Any(t => !policy.Contains(t))) return null;
        return policy;
    }

    /// <summary>CLI 后端的技能简报：外部代理没有内置工具循环，必须显式告知内置技能
    /// 的调用方式与组件安装的同意边界，否则会徒手重写技能甚至擅自安装系统软件
    /// （与 macOS 端 ChatViewModel.cliSkillsBrief 对齐）。</summary>
    public static string CliSkillsBrief
    {
        get
        {
            var catalog = Catalog;
            if (string.IsNullOrWhiteSpace(catalog) ||
                !File.Exists(PythonExe) || !File.Exists(Toolbox)) return "";
            var bin = Path.Combine(ActiveRuntimeRoot, "bin");
            var binLine = Directory.Exists(bin)
                ? $"专用工具目录（ffmpeg 等已下载组件）已加入 PATH：{bin}\n"
                : "";
            return
                "Folderis 内置技能工具箱：涉及下列技能覆盖的文件处理时必须优先调用，禁止另写脚本重复实现，" +
                "也禁止未经用户明确同意安装任何系统软件（winget/pip/npm 等同样受限；可选组件一律先征求用户同意，经 install-component 安装）。\n" +
                "调用方式（终端中执行，cwd 即任务文件夹）：\n" +
                $"\"{PythonExe}\" \"{Toolbox}\" <技能名> <参数…>\n" +
                binLine + catalog;
        }
    }

    /// <summary>OpenAI function-calling 的工具声明：单一 run_skill 入口。</summary>
    public static readonly JsonArray ToolSchema = new(
        new JsonObject
        {
            ["type"] = "function",
            ["function"] = new JsonObject
            {
                ["name"] = "run_skill",
                ["description"] = "运行一个预置技能（见系统提示中的技能目录）。默认保留原文件和全部历史产物，并使用唯一的新文件名；只有用户明确要求覆盖时才可传 --overwrite-original。",
                ["parameters"] = new JsonObject
                {
                    ["type"] = "object",
                    ["properties"] = new JsonObject
                    {
                        ["skill"] = new JsonObject { ["type"] = "string" },
                        ["args"] = new JsonObject
                        {
                            ["type"] = "array",
                            ["items"] = new JsonObject { ["type"] = "string" }
                        },
                        ["cwd"] = new JsonObject { ["type"] = "string" }
                    },
                    ["required"] = new JsonArray("skill")
                }
            }
        });

    public async Task<string> RunAsync(
        string skill, string[] args, string cwd, CancellationToken ct)
    {
        // 首用引导：运行时缺失时不直接报错，而是指导模型征求用户同意后自装。
        if (skill == "install-runtime")
        {
            if (HasRuntime(BundledRuntimeRoot) || HasRuntime(SupportRoot))
                return L10n.T("技能运行时已随应用安装，无需下载。", "Skills runtime is bundled; no download is needed.");
            return await InstallRuntimeAsync(ct);
        }
        if (!File.Exists(PythonExe) || !File.Exists(Toolbox))
            return L10n.T(
                "技能运行时未安装。请询问用户：首次使用技能需一次性下载 Python 组件（约 30MB，来自 python.org 官方）。" +
                "用户同意后调用 run_skill，skill 填 install-runtime；拒绝则说明技能不可用（普通对话不受影响）。",
                "Skills runtime not installed. Ask the user: first-time skill use needs a one-time ~30MB Python download " +
                "(from python.org). On consent call run_skill with skill=install-runtime; if declined, explain skills are unavailable.");

        var psi = new ProcessStartInfo
        {
            FileName = PythonExe,
            WorkingDirectory = cwd,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        psi.ArgumentList.Add(Toolbox);
        psi.ArgumentList.Add(skill);
        foreach (var a in args) psi.ArgumentList.Add(a);
        // Skills execute from the fresh bundled runtime, while optional
        // multi-GB components/models live in persistent app support so an app
        // upgrade does not force the user to download them again.
        psi.Environment["FOLDERIS_SUPPORT_DIR"] = SupportRoot;

        using var proc = Process.Start(psi)!;
        using var cancellation = ct.Register(() =>
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
        });
        var stdout = proc.StandardOutput.ReadToEndAsync(ct);
        var stderr = proc.StandardError.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);

        var output = (await stdout) + (await stderr);
        if (output.Length <= 20_000) return output;
        if (skill == "local-dispatch")
        {
            const string marker = "__FOLDERIS_LOCAL_RESULT__";
            var markerIndex = output.LastIndexOf(marker, StringComparison.Ordinal);
            if (markerIndex >= 0) return output[markerIndex..];
        }
        return output[..20_000] + "\n…（输出已截断）";
    }

    private const string PyVersion = "3.12.8";

    /// <summary>下载 python 嵌入版 + pip 依赖，并释放内嵌的 skills.py/catalog.txt。</summary>
    private static async Task<string> InstallRuntimeAsync(CancellationToken ct)
    {
        try
        {
            var pyDir = Path.Combine(SupportRoot, "python");
            var skillsDir = Path.Combine(SupportRoot, "skills");
            var py = Path.Combine(pyDir, "python.exe");
            // 上次装到一半的残骸：整个目录清掉重来，避免"半个 python"卡死后续步骤
            if (Directory.Exists(pyDir) && !File.Exists(py))
                Directory.Delete(pyDir, recursive: true);
            Directory.CreateDirectory(pyDir);
            Directory.CreateDirectory(skillsDir);
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(4) };

            // 每个资源都：国内镜像优先，官方源兜底
            async Task<byte[]> FetchAsync(string what, params string[] urls)
            {
                Exception? lastErr = null;
                foreach (var u in urls)
                {
                    try { return await http.GetByteArrayAsync(u, ct); }
                    catch (Exception e) { lastErr = e; }
                }
                throw new Exception($"{what} 下载失败（镜像与官方源都未成功）：{lastErr?.Message}");
            }

            // 1) python 嵌入版
            if (!File.Exists(py))
            {
                var zipPath = Path.Combine(SupportRoot, "py.zip");
                var bytes = await FetchAsync("Python",
                    $"https://registry.npmmirror.com/-/binary/python/{PyVersion}/python-{PyVersion}-embed-amd64.zip",
                    $"https://www.python.org/ftp/python/{PyVersion}/python-{PyVersion}-embed-amd64.zip");
                await File.WriteAllBytesAsync(zipPath, bytes, ct);
                System.IO.Compression.ZipFile.ExtractToDirectory(zipPath, pyDir, overwriteFiles: true);
                File.Delete(zipPath);
                var pth = Directory.GetFiles(pyDir, "python3*._pth").FirstOrDefault();
                if (pth is not null)
                    File.WriteAllText(pth, File.ReadAllText(pth).Replace("#import site", "import site"));
            }

            // 2) pip
            var getPip = Path.Combine(SupportRoot, "get-pip.py");
            await File.WriteAllBytesAsync(getPip, await FetchAsync("pip 引导脚本",
                "https://mirrors.aliyun.com/pypi/get-pip.py",
                "https://bootstrap.pypa.io/get-pip.py"), ct);
            var r1 = await RunProcessAsync(py, new[] { getPip, "--no-warn-script-location",
                "-i", "https://pypi.tuna.tsinghua.edu.cn/simple" }, ct);
            if (r1.code != 0)
                r1 = await RunProcessAsync(py, new[] { getPip, "--no-warn-script-location" }, ct);
            File.Delete(getPip);
            if (r1.code != 0) return "pip 安装失败：" + r1.output[^Math.Min(400, r1.output.Length)..];

            // 3) 依赖（清华镜像优先，失败回退官方 PyPI）
            var deps = new[]
            {
                "pypdf", "openpyxl", "Pillow", "chardet", "python-docx", "pillow-heif",
                "pywin32", "pymupdf", "qrcode", "zxing-cpp", "winocr", "pyzipper", "xlrd"
            };
            var mirror = new[] { "-m", "pip", "install", "--no-warn-script-location",
                "-i", "https://pypi.tuna.tsinghua.edu.cn/simple" }.Concat(deps).ToArray();
            var r2 = await RunProcessAsync(py, mirror, ct);
            if (r2.code != 0)
                r2 = await RunProcessAsync(py,
                    new[] { "-m", "pip", "install", "--no-warn-script-location" }.Concat(deps).ToArray(), ct);
            if (r2.code != 0) return "依赖安装失败：" + r2.output[^Math.Min(400, r2.output.Length)..];

            // 4) pywin32 需要注册步骤（尽力而为，失败不阻塞其他技能）
            await RunProcessAsync(py, new[] { "-m", "pywin32_postinstall", "-install", "-quiet" }, ct);

            // 5) 释放内嵌的技能脚本
            ExtractResource("skills.py", Path.Combine(skillsDir, "skills.py"));
            ExtractResource("catalog.txt", Path.Combine(skillsDir, "catalog.txt"));
            File.WriteAllText(Path.Combine(SupportRoot, "SKILLS_VERSION"),
                ComputeSkillsVersion(SupportRoot));

            return L10n.T(
                "技能运行时安装完成，所有跨平台技能已可用。请告知用户，并继续执行其原始请求。" +
                "（注意：文档转 PDF 需本机装有 Word 或 WPS；音视频/抠图/转写/分卷等重组件按需引导安装。）",
                "Skills runtime installed. Cross-platform skills are ready — tell the user and continue their original request. " +
                "(Note: doc-to-PDF needs Word or WPS installed; heavy components — ffmpeg, transcription, " +
                "background removal, split archives — are installed on demand with user consent.)");
        }
        catch (Exception e)
        {
            return L10n.T($"运行时安装失败：{e.Message}。请检查网络后重试。",
                          $"Runtime install failed: {e.Message}. Check the network and retry.");
        }
    }

    private static void ExtractResource(string name, string dest)
    {
        using var res = System.Reflection.Assembly.GetExecutingAssembly()
            .GetManifestResourceStream(name) ?? throw new InvalidOperationException($"资源缺失 {name}");
        using var f = File.Create(dest);
        res.CopyTo(f);
    }

    private static async Task<(int code, string output)> RunProcessAsync(
        string exe, string[] args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var so = p.StandardOutput.ReadToEndAsync(ct);
        var se = p.StandardError.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct);
        return (p.ExitCode, await so + await se);
    }
}
