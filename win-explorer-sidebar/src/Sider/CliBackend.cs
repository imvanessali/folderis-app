using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;

namespace Sider;

/// <summary>
/// CLI 后端：驱动本机已登录的 Claude Code / Codex，用量走用户订阅。
/// 与 macOS 版同一套协议（claude -p stream-json / codex exec --json）。
/// </summary>
public enum BackendKind { BuiltinApi, ClaudeCode, Codex }

public sealed class CliBackend
{
    /// <summary>每后端一个会话 id（resume 用），由调用方按会话持久化。</summary>
    public Dictionary<string, string> SessionIds { get; set; } = [];

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

    public async Task<string?> RunAsync(
        BackendKind kind, string cliPath, string prompt, string cwd, bool yolo,
        Action<string> onDelta, Action<string> onActivity, CancellationToken ct)
    {
        var key = kind.ToString();
        var args = new List<string>();
        if (kind == BackendKind.ClaudeCode)
        {
            args.AddRange(["-p", prompt, "--output-format", "stream-json", "--verbose"]);
            if (SessionIds.TryGetValue(key, out var sid)) args.AddRange(["--resume", sid]);
            args.AddRange(yolo ? ["--dangerously-skip-permissions"] : ["--permission-mode", "acceptEdits"]);
        }
        else
        {
            if (SessionIds.TryGetValue(key, out var sid)) args.AddRange(["exec", "resume", sid, "--json"]);
            else args.AddRange(["exec", "--json"]);
            args.Add(yolo ? "--dangerously-bypass-approvals-and-sandbox" : "--full-auto");
            args.Add(prompt);
        }

        var psi = new ProcessStartInfo
        {
            FileName = cliPath,
            WorkingDirectory = cwd,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8
        };
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
        // 净化可能干扰 CLI 自身认证的变量（按前缀）
        foreach (var k in psi.Environment.Keys.Where(k =>
            k.StartsWith("ANTHROPIC_") || k.StartsWith("CLAUDE") || k.StartsWith("OPENAI_")).ToList())
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

            if (kind == BackendKind.ClaudeCode)
            {
                var type = eventType;
                if (type == "assistant" && node["message"]?["content"] is JsonArray blocks)
                {
                    foreach (var b in blocks)
                    {
                        if ((string?)b?["type"] == "text" && (string?)b?["text"] is { } t)
                        {
                            onDelta((appended ? "\n\n" : "") + t);
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
                        streamedFailure = raw.Contains("authenticat", StringComparison.OrdinalIgnoreCase)
                            ? L10n.T("Claude Code 登录已过期：请在终端运行 claude 重新登录后重试", "Claude Code login expired — run `claude` in a terminal to sign in again, then retry")
                            : $"Claude Code 出错：{raw[..Math.Min(200, raw.Length)]}";
                    }
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
            var detail = string.IsNullOrWhiteSpace(stderr)
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
