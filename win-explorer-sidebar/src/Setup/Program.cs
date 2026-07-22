using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;

// Folderis Windows 安装器（无 UI 框架，系统 API 弹窗）：
// 解压内嵌 payload 到用户目录 → 建快捷方式 → 启动。免管理员。
static class Setup
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(nint hwnd, string text, string caption, uint type);

    static readonly string LogPath = Path.Combine(
        Path.GetTempPath(), "Folderis-Setup.log");

    static void Log(string message)
    {
        try
        {
            File.AppendAllText(LogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}{Environment.NewLine}");
        }
        catch { }
    }

    [STAThread]
    static void Main()
    {
        string assemblyName = Assembly.GetExecutingAssembly().GetName().Name ?? "Folderis-Setup";
        string appName = assemblyName.StartsWith("Folderis-Lite-Setup", StringComparison.OrdinalIgnoreCase)
            ? "Folderis Lite"
            : "Folderis";
        string installDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs", appName);
        string stagingDir = installDir + $".installing-{Environment.ProcessId}";

        Log($"Starting {appName} setup. Version={Assembly.GetExecutingAssembly().GetName().Version}; " +
            $"OS={Environment.OSVersion}; x64={Environment.Is64BitOperatingSystem}; target={installDir}");

        MessageBoxW(0,
            $"正在安装 {appName}。点击确定后请稍候，Windows 安全扫描可能需要一分钟。\n\n" +
            $"Installing {appName}. Click OK and wait; Windows security scanning may take up to a minute.\n\n" +
            $"安装日志 / Setup log:\n{LogPath}",
            appName, 0x40);

        try
        {
            if (Directory.Exists(stagingDir))
                Directory.Delete(stagingDir, recursive: true);
            Directory.CreateDirectory(stagingDir);

            using var res = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream("payload.zip")
                ?? throw new InvalidDataException("安装包缺少 payload.zip / payload.zip is missing");
            Log($"Extracting embedded payload ({res.Length} bytes) to {stagingDir}");
            using (var zip = new ZipArchive(res, ZipArchiveMode.Read))
                zip.ExtractToDirectory(stagingDir);

            string expectedExe = Path.Combine(stagingDir,
                appName.Equals("Folderis Lite", StringComparison.OrdinalIgnoreCase)
                    ? "Folderis Lite.exe" : "Folderis.exe");
            string stagedExe = File.Exists(expectedExe)
                ? expectedExe
                : Directory.GetFiles(stagingDir, "*.exe", SearchOption.TopDirectoryOnly)
                    .OrderByDescending(f => new FileInfo(f).Length)
                    .FirstOrDefault()
                    ?? throw new InvalidDataException("安装内容中找不到 Folderis.exe / Folderis.exe is missing");
            Log($"Payload verified. App={stagedExe}; bytes={new FileInfo(stagedExe).Length}");

            foreach (var name in new[] { "Folderis Lite", "Folderis", "ExplorerSidebarLite", "ExplorerSidebar" })
            {
                foreach (var p in System.Diagnostics.Process.GetProcessesByName(name))
                {
                    try
                    {
                        Log($"Stopping existing process {p.ProcessName} pid={p.Id}");
                        p.Kill();
                        p.WaitForExit(5000);
                    }
                    catch (Exception ex) { Log($"Could not stop pid={p.Id}: {ex.Message}"); }
                    finally { p.Dispose(); }
                }
            }

            if (Directory.Exists(installDir))
                Directory.Delete(installDir, recursive: true);
            Directory.Move(stagingDir, installDir);
            Log("Staging directory promoted to the final install directory");

            var exe = Path.Combine(installDir, Path.GetFileName(stagedExe));
            if (!File.Exists(exe))
                throw new FileNotFoundException("安装完成后找不到主程序 / Installed app is missing", exe);
            var exeDir = Path.GetDirectoryName(exe)!;

            string desktop = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Desktop), appName + ".lnk");
            string startMenu = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
                "Programs", appName + ".lnk");
            MakeShortcut(desktop, exe, exeDir);
            MakeShortcut(startMenu, exe, exeDir);

            PurgeStaleSupportRuntime(exeDir);

            Log($"Launching {exe}");
            using var launched = System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo(exe)
                { WorkingDirectory = exeDir, UseShellExecute = true })
                ?? throw new InvalidOperationException("Windows 未能启动 Folderis / Windows did not start Folderis");
            if (launched.WaitForExit(2500))
                throw new InvalidOperationException(
                    $"Folderis 启动后立即退出，代码 {launched.ExitCode}。" +
                    $"请查看 %LOCALAPPDATA%\\Sider\\error.log 和 startup.log / " +
                    $"Folderis exited immediately with code {launched.ExitCode}.");
            Log($"Folderis is still running after startup check. pid={launched.Id}");

            MessageBoxW(0,
                $"{appName} 安装完成，已启动。\n安装位置：{installDir}\n桌面与开始菜单已创建快捷方式。\n\n" +
                $"Installed and launched. Shortcuts created.\n\n安装日志 / Setup log:\n{LogPath}",
                appName, 0x40);
        }
        catch (Exception ex)
        {
            Log("FAILED: " + ex);
            MessageBoxW(0,
                "安装失败 / Install failed:\n\n" + ex.Message +
                "\n\n请把这个日志发给我 / Send this log:\n" + LogPath,
                appName, 0x10);
        }
        finally
        {
            try
            {
                if (Directory.Exists(stagingDir))
                    Directory.Delete(stagingDir, recursive: true);
            }
            catch (Exception ex) { Log("Could not clean staging directory: " + ex.Message); }
        }
    }

    /// <summary>
    /// SkillRunner.ActiveRuntimeRoot prefers the runtime bundled next to the exe
    /// (fresh on every install) and only falls back to the persistent support
    /// directory (%LOCALAPPDATA%\Sider) when no bundled runtime is present. A
    /// stale skills.py left over in the support directory from an old
    /// download-based install (or ad-hoc test tooling that hardcodes that path
    /// instead of resolving it the way the app does) is therefore invisible to
    /// the running app — but it is a real trap for anything else that reads
    /// that path directly. Once we know this build ships its own runtime, wipe
    /// the leftover copy so there is only ever one place to look. Settings,
    /// the API key, conversation history, and logs live in the same directory
    /// but are never touched here.
    /// </summary>
    static void PurgeStaleSupportRuntime(string exeDir)
    {
        try
        {
            var bundledRuntime = Path.Combine(exeDir, "runtime");
            bool hasBundledRuntime =
                File.Exists(Path.Combine(bundledRuntime, "python", "python.exe")) &&
                File.Exists(Path.Combine(bundledRuntime, "skills", "skills.py"));
            if (!hasBundledRuntime)
            {
                Log("No bundled runtime in this build; leaving %LOCALAPPDATA%\\Sider runtime files as the active fallback.");
                return;
            }

            var supportDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sider");
            foreach (var name in new[] { "skills", "bin", "python" })
            {
                var stale = Path.Combine(supportDir, name);
                if (!Directory.Exists(stale)) continue;
                Directory.Delete(stale, recursive: true);
                Log($"Removed stale support-directory runtime folder: {stale}");
            }
        }
        catch (Exception ex)
        {
            // Never fail the install over this — the app still works from the
            // bundled runtime either way.
            Log("Could not purge stale support runtime (non-fatal): " + ex.Message);
        }
    }

    static void MakeShortcut(string lnk, string target, string workDir)
    {
        // PowerShell 建 .lnk：避免引入 COM interop/dynamic（可裁剪、体积小）
        static string PsQuote(string value) => value.Replace("'", "''");
        var script =
            $"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{PsQuote(lnk)}');" +
            $"$s.TargetPath='{PsQuote(target)}';$s.WorkingDirectory='{PsQuote(workDir)}';$s.Save()";
        var psi = new System.Diagnostics.ProcessStartInfo("powershell.exe")
        { CreateNoWindow = true, UseShellExecute = false };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-WindowStyle");
        psi.ArgumentList.Add("Hidden");
        psi.ArgumentList.Add("-Command");
        psi.ArgumentList.Add(script);
        try
        {
            using var process = System.Diagnostics.Process.Start(psi);
            if (process is null || !process.WaitForExit(8000) || process.ExitCode != 0)
                Log($"Shortcut creation did not complete successfully: {lnk}");
            else
                Log($"Shortcut created: {lnk}");
        }
        catch (Exception ex) { Log($"Shortcut creation failed ({lnk}): {ex.Message}"); }
    }
}
