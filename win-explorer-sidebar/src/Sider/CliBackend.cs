using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;

namespace Sider;

/// <summary>
/// CLI 后端：驱动本机已登录的 Claude Code / Codex / Cursor，用量走用户订阅。
/// 与 macOS 版使用同一套 CLI 流式协议。
/// </summary>
public enum BackendKind { BuiltinApi, ClaudeCode, Codex, Cursor }

public sealed class CliBackend
{

    public static string? DetectPath(string name)
    {
        // npm 全局装的是 .cmd，原生安装器装的是 .exe，两种都认。
        var exeNames = OperatingSystem.IsWindows()
            ? new[] { name + ".cmd", name + ".exe" }
            : new[] { name };
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var dirs = new List<string>
        {
            Path.Combine(home, ".local", "bin"),
            Path.Combine(home, "AppData", "Roaming", "npm"),
        };
        foreach (var dir in dirs)
            foreach (var exe in exeNames)
            {
                var c = Path.Combine(dir, exe);
                if (File.Exists(c)) return c;
            }

        // PATH 兜底
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            foreach (var exe in exeNames)
            {
                var p = Path.Combine(dir.Trim(), exe);
                if (File.Exists(p)) return p;
            }

        // Codex 桌面版内置 CLI（与桌面版共用登录态；macOS 版同款能力）。
        // 路径按 Electron 常规布局推测，需真机验证。
        if (name == "codex" && OperatingSystem.IsWindows())
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var guesses = new[]
            {
                Path.Combine(local, "Programs", "ChatGPT", "resources", "codex.exe"),
                Path.Combine(local, "Programs", "ChatGPT", "Resources", "codex.exe"),
                Path.Combine(local, "Programs", "Codex", "resources", "codex.exe"),
                Path.Combine(local, "Programs", "codex", "resources", "codex.exe"),
            };
            foreach (var g in guesses)
                if (File.Exists(g)) return g;
        }
        return null;
    }

    /// <summary>Cursor Agent 新版命令为 cursor-agent，兼容早期 agent 别名。</summary>
    public static string? DetectCursorPath()
    {
        if (DetectPath("cursor-agent") is { } current) return current;
        if (OperatingSystem.IsWindows())
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var nativeLaunchers = new[]
            {
                Path.Combine(local, "cursor-agent", "cursor-agent.ps1"),
                Path.Combine(local, "cursor-agent", "agent.ps1")
            };
            if (nativeLaunchers.FirstOrDefault(File.Exists) is { } launcher)
                return launcher;
        }
        // `agent` is a generic name, so only trust directories used by
        // Cursor's legacy installer instead of scanning all of PATH.
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var exeNames = OperatingSystem.IsWindows()
            ? new[] { "agent.cmd", "agent.exe" }
            : new[] { "agent" };
        var dirs = new[]
        {
            Path.Combine(home, ".local", "bin"),
            Path.Combine(home, ".cursor", "bin")
        };
        return dirs.SelectMany(dir => exeNames.Select(exe => Path.Combine(dir, exe)))
            .FirstOrDefault(File.Exists);
    }

    /// <summary>sessions：每后端一个会话 id（resume 用），由调用方按会话捕获传入——
    /// 面板显示切走后任务仍 resume 自己会话的 id。</summary>
    public async Task<string?> RunAsync(
        BackendKind kind, string cliPath, string prompt, string cwd, bool yolo,
        Dictionary<string, string> sessions,
        Action<string> onDelta, Action<string> onActivity, CancellationToken ct)
    {
        var key = kind.ToString();
        var args = new List<string>();
        // Claude Code 经 --append-system-prompt 注入技能简报；codex/cursor 无对应
        // 参数，简报并入提示词开头（与 macOS 端 runCLIBackendTurn 对齐）。
        var skillsBrief = SkillRunner.CliSkillsBrief;
        if (skillsBrief.Length > 0 && kind != BackendKind.ClaudeCode)
            prompt = skillsBrief + "\n\n" + prompt;
        if (kind == BackendKind.ClaudeCode)
        {
            args.AddRange(["-p", prompt, "--output-format", "stream-json", "--verbose"]);
            if (skillsBrief.Length > 0) args.AddRange(["--append-system-prompt", skillsBrief]);
            if (sessions.TryGetValue(key, out var sid)) args.AddRange(["--resume", sid]);
            args.AddRange(yolo ? ["--dangerously-skip-permissions"] : ["--permission-mode", "acceptEdits"]);
        }
        else if (kind == BackendKind.Codex)
        {
            if (sessions.TryGetValue(key, out var sid)) args.AddRange(["exec", "resume", sid, "--json"]);
            else args.AddRange(["exec", "--json"]);
            args.Add(yolo ? "--dangerously-bypass-approvals-and-sandbox" : "--full-auto");
            args.Add(prompt);
        }
        else
        {
            args.AddRange([
                "-p", prompt,
                "--output-format", "stream-json",
                "--stream-partial-output"
            ]);
            if (sessions.TryGetValue(key, out var sid)) args.AddRange(["--resume", sid]);
            // Cursor print mode only writes files when --force is enabled.
            if (yolo) args.Add("--force");
        }

        var isPowerShellLauncher = OperatingSystem.IsWindows()
            && cliPath.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase);
        var psi = new ProcessStartInfo
        {
            FileName = isPowerShellLauncher
                ? Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe")
                : cliPath,
            WorkingDirectory = cwd,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8
        };
        if (isPowerShellLauncher)
            foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", cliPath })
                psi.ArgumentList.Add(a);
        foreach (var a in args) psi.ArgumentList.Add(a);
        // Keep GUI launches aligned with terminal launches: the detected CLI
        // directory can contain its runtime (for example node.exe or a shim)
        // even when Explorer's inherited PATH does not include that directory.
        var cliDirectory = Path.GetDirectoryName(Path.GetFullPath(cliPath));
        if (!string.IsNullOrEmpty(cliDirectory))
        {
            var pathEntries = (psi.Environment["PATH"] ?? "")
                .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
            if (!pathEntries.Contains(cliDirectory, StringComparer.OrdinalIgnoreCase))
                psi.Environment["PATH"] = cliDirectory + Path.PathSeparator
                    + (psi.Environment["PATH"] ?? "");
        }
        // 技能简报中承诺的专用工具目录（ffmpeg 等下载组件）对 CLI 可见。
        var skillsBin = Path.Combine(SkillRunner.RuntimeRoot, "bin");
        if (Directory.Exists(skillsBin))
        {
            var entries = (psi.Environment["PATH"] ?? "")
                .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
            if (!entries.Contains(skillsBin, StringComparer.OrdinalIgnoreCase))
                psi.Environment["PATH"] = (psi.Environment["PATH"] ?? "")
                    + Path.PathSeparator + skillsBin;
        }
        // 净化可能干扰 CLI 自身认证的变量（按前缀）
        foreach (var k in psi.Environment.Keys.Where(k =>
            k.StartsWith("ANTHROPIC_") || k.StartsWith("CLAUDE") || k.StartsWith("OPENAI_")
            || k == "CURSOR_API_KEY").ToList())
            psi.Environment.Remove(k);

        using var proc = Process.Start(psi)!;
        using var reg = ct.Register(() => { try { proc.Kill(true); } catch { } });
        var stderrTask = proc.StandardError.ReadToEndAsync(ct);

        var appended = false;
        var completedNormally = false;
        string? streamedFailure = null;
        string? discoveredSessionId = null;
        while (await proc.StandardOutput.ReadLineAsync(ct) is { } line)
        {
            JsonNode? node;
            try { node = JsonNode.Parse(line); } catch { continue; }
            if (node is null) continue;

            if ((string?)node["session_id"] is { } s1) discoveredSessionId = s1;
            if ((string?)node["thread_id"] is { } s2) discoveredSessionId = s2;

            var eventType = (string?)node["type"];
            if (kind == BackendKind.Codex)
            {
                if (eventType == "turn.completed") completedNormally = true;
                if (eventType is "turn.failed" or "error")
                    streamedFailure = ErrorText(node) ?? L10n.T("Codex 任务失败", "Codex task failed");
            }

            if (kind is BackendKind.ClaudeCode or BackendKind.Cursor)
            {
                var type = eventType;
                if (type == "assistant" && node["message"]?["content"] is JsonArray blocks)
                {
                    if (kind == BackendKind.Cursor
                        && (node["timestamp_ms"] is null || node["model_call_id"] is not null))
                        continue;
                    foreach (var b in blocks)
                    {
                        if ((string?)b?["type"] == "text" && (string?)b?["text"] is { } t)
                        {
                            onDelta((appended && kind == BackendKind.ClaudeCode ? "\n\n" : "") + t);
                            appended = true;
                        }
                        else if ((string?)b?["type"] == "tool_use" && (string?)b?["name"] is { } n)
                            onActivity($"🔧 {n}");
                    }
                }
                else if (type == "result")
                {
                    completedNormally = true;
                    if ((bool?)node["is_error"] == true)
                    {
                        var raw = (string?)node["result"] ?? L10n.T("未知错误", "unknown error");
                        var authFailure = raw.Contains("authenticat", StringComparison.OrdinalIgnoreCase)
                            || raw.Contains("logged in", StringComparison.OrdinalIgnoreCase);
                        streamedFailure = authFailure
                            ? kind == BackendKind.Cursor
                                ? L10n.T("Cursor 未登录：请在终端运行 cursor-agent login 后重试", "Cursor is not signed in — run `cursor-agent login` in a terminal, then retry")
                                : L10n.T("Claude Code 登录已过期：请在终端运行 claude 重新登录后重试", "Claude Code login expired — run `claude` in a terminal to sign in again, then retry")
                            : $"{kind} 出错：{raw[..Math.Min(200, raw.Length)]}";
                    }
                    else if (!appended && (string?)node["result"] is { Length: > 0 } finalText)
                    {
                        onDelta(finalText);
                        appended = true;
                    }
                }
                else if (kind == BackendKind.Cursor
                         && type == "tool_call"
                         && (string?)node["subtype"] == "started"
                         && node["tool_call"] is JsonObject toolCall)
                {
                    var toolName = toolCall.Select(kv => kv.Key).FirstOrDefault();
                    if (!string.IsNullOrEmpty(toolName)) onActivity($"🔧 {toolName}");
                }
            }
            else if (node["item"] is JsonObject item
                     && (string?)item["type"] == "agent_message"
                     && (string?)item["text"] is { } text)
            {
                onDelta((appended ? "\n\n" : "") + text);
                appended = true;
            }
        }
        await proc.WaitForExitAsync(ct);
        var stderr = (await stderrTask).Trim();
        if (!string.IsNullOrWhiteSpace(streamedFailure))
        {
            if (proc.ExitCode != 0)
                throw CommandFailure(kind, proc.ExitCode, streamedFailure);
            throw new InvalidOperationException(streamedFailure);
        }
        if (proc.ExitCode != 0)
        {
            var cursorAuthFailure = kind == BackendKind.Cursor
                && (stderr.Contains("authentication required", StringComparison.OrdinalIgnoreCase)
                    || stderr.Contains("not logged in", StringComparison.OrdinalIgnoreCase)
                    || stderr.Contains("not authenticated", StringComparison.OrdinalIgnoreCase));
            var detail = cursorAuthFailure
                ? L10n.T("Cursor 未登录：请在终端运行 cursor-agent login 后重试",
                         "Cursor is not signed in — run `cursor-agent login` in a terminal, then retry")
                : string.IsNullOrWhiteSpace(stderr)
                ? L10n.T("进程异常退出", "process exited unexpectedly")
                : stderr[..Math.Min(500, stderr.Length)];
            throw CommandFailure(kind, proc.ExitCode, detail);
        }
        if (!completedNormally)
            throw new InvalidOperationException(L10n.T(
                $"{kind} 未正常完成任务，请重试。已显示的内容只是中间进度，不代表文件已生成。",
                $"{kind} did not complete normally. Retry; any text already shown was progress, not a completed file."));
        return discoveredSessionId;
    }

    private static InvalidOperationException CommandFailure(
        BackendKind kind, int exitCode, string detail) =>
        new(L10n.T(
            $"{kind} 命令执行失败（退出码 {exitCode}）：{detail}",
            $"{kind} command failed (exit code {exitCode}): {detail}"));

    private static string? ErrorText(JsonNode node)
    {
        if ((string?)node["message"] is { Length: > 0 } message) return message;
        if (node["error"] is JsonValue value && value.TryGetValue<string>(out var error)) return error;
        if (node["error"] is JsonObject obj)
            return (string?)obj["message"] ?? (string?)obj["detail"];
        return null;
    }
}
