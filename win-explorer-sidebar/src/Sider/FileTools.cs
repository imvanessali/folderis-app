using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Sider;

/// <summary>
/// 文件工具九件套 + 命令执行：对齐 macOS 版 executeTool 的语义与守卫
/// （相对路径、根目录越界防护、200KB 读取上限、edit 唯一匹配）。
/// </summary>
public sealed class FileTools
{
    public string? Root { get; set; }

    /// <summary>run_command 审批回调：返回是否放行（UI 层弹确认卡）。</summary>
    public Func<string, string?, Task<bool>>? ApprovalHandler { get; set; }
    public string ApprovalMode { get; set; } = "ask"; // ask | safeAuto | yolo

    public static readonly string[] ToolNames =
    [
        "list_files", "read_file", "write_file", "edit_file", "move_file",
        "copy_file", "trash_file", "make_directory", "search_files", "run_command"
    ];

    /// <summary>OpenAI function-calling 声明（与 mac 版 toolsSpec 对齐）。</summary>
    public static JsonArray BuildSchema()
    {
        static JsonObject Tool(string name, string desc, JsonObject props, params string[] required) => new()
        {
            ["type"] = "function",
            ["function"] = new JsonObject
            {
                ["name"] = name,
                ["description"] = desc,
                ["parameters"] = new JsonObject
                {
                    ["type"] = "object",
                    ["properties"] = props,
                    ["required"] = new JsonArray(required.Select(r => (JsonNode)r).ToArray())
                }
            }
        };
        static JsonObject P(string type, string desc) => new() { ["type"] = type, ["description"] = desc };

        return new JsonArray(
            Tool("list_files", "列出工作目录中的文件和子目录",
                new JsonObject { ["path"] = P("string", "相对路径，省略表示根目录") }),
            Tool("read_file", "读取工作目录内一个文本文件的完整内容",
                new JsonObject { ["path"] = P("string", "相对路径") }, "path"),
            Tool("write_file", "在工作目录内创建文本文件。目标已存在时默认自动另存为 _2、_3 等唯一名称；只有用户明确要求覆盖该文件时才可传 overwrite=true。",
                new JsonObject
                {
                    ["path"] = P("string", "相对路径"),
                    ["content"] = P("string", "文件完整内容"),
                    ["overwrite"] = P("boolean", "仅当用户明确要求覆盖现有文件时设为 true；默认 false")
                },
                "path", "content"),
            Tool("edit_file", "对已有文本文件做精确字符串替换。只有用户明确要求修改该文件时才可传 overwrite=true；否则禁止修改。old_string 必须与文件内容完全一致。",
                new JsonObject
                {
                    ["path"] = P("string", "相对路径"),
                    ["old_string"] = P("string", "要被替换的原文（须精确匹配）"),
                    ["new_string"] = P("string", "替换后的内容"),
                    ["replace_all"] = P("boolean", "是否替换所有出现，默认 false"),
                    ["overwrite"] = P("boolean", "用户明确要求修改现有文件时必须设为 true")
                }, "path", "old_string", "new_string"),
            Tool("move_file", "移动或重命名工作目录内的文件/文件夹",
                new JsonObject { ["from"] = P("string", "现路径（相对）"), ["to"] = P("string", "新路径（相对）") },
                "from", "to"),
            Tool("copy_file", "复制工作目录内的文件/文件夹",
                new JsonObject { ["from"] = P("string", "源路径（相对）"), ["to"] = P("string", "目标路径（相对）") },
                "from", "to"),
            Tool("trash_file", "把工作目录内的文件/文件夹移到回收站（可恢复）",
                new JsonObject { ["path"] = P("string", "相对路径") }, "path"),
            Tool("make_directory", "在工作目录内新建文件夹（自动创建中间目录）",
                new JsonObject { ["path"] = P("string", "相对路径") }, "path"),
            Tool("search_files", "在工作目录的文本文件内容中按正则表达式搜索，返回 文件:行号:行内容 列表",
                new JsonObject
                {
                    ["pattern"] = P("string", "正则表达式"),
                    ["path"] = P("string", "限定搜索的子目录（相对路径），省略为整个工作目录")
                }, "pattern"),
            Tool("run_command", "在工作目录执行一条命令（cmd /c）。运行脚本、git、构建等。每条命令可能需要用户确认，被拒绝时返回拒绝信息。",
                new JsonObject
                {
                    ["command"] = P("string", "要执行的完整命令"),
                    ["purpose"] = P("string", "一句话说明这条命令的目的（显示给用户）")
                }, "command"));
    }

    /// <summary>相对路径解析 + 越界防护（对齐 mac resolveInFolder）。</summary>
    private string? Resolve(string rel)
    {
        if (Root is null) return null;
        var target = Path.GetFullPath(Path.Combine(Root, rel));
        var root = Path.GetFullPath(Root);
        return target == root || target.StartsWith(root + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase) ? target : null;
    }

    private static string OutputCandidate(string requested, int index)
    {
        if (index == 1) return requested;
        var directory = Path.GetDirectoryName(requested)!;
        var extension = Path.GetExtension(requested);
        var stem = Path.GetFileNameWithoutExtension(requested);
        return Path.Combine(directory, $"{stem}_{index}{extension}");
    }

    // 只读命令白名单分类器（移植 mac isReadOnlyCommand）
    private static readonly string[] ReadOnlyPrefixes =
    [
        "dir", "type", "where", "whoami", "echo", "findstr", "tree", "cd",
        "git status", "git log", "git diff", "git show", "git branch",
        "python --version", "pip list", "pip show", "systeminfo", "ver", "tasklist"
    ];

    private static bool IsReadOnly(string cmd)
    {
        var c = cmd.Trim().ToLowerInvariant();
        if (c.Contains("&&") || c.Contains("||") || c.Contains('|') || c.Contains('>')) return false;
        return ReadOnlyPrefixes.Any(p => c == p || c.StartsWith(p + " "));
    }

    public async Task<string> ExecuteAsync(string name, JsonObject input, CancellationToken ct)
    {
        if (Root is null) return "错误：当前未绑定文件夹，无法使用文件工具";
        var path = (string?)input["path"] ?? "";

        switch (name)
        {
            case "list_files":
            {
                var dir = Resolve(path.Length == 0 ? "." : path);
                if (dir is null) return "错误：路径越界";
                if (!Directory.Exists(dir)) return "错误：目录不存在";
                var sb = new StringBuilder();
                var count = 0;
                foreach (var entry in Directory.EnumerateFileSystemEntries(dir, "*", new EnumerationOptions
                         { RecurseSubdirectories = true, MaxRecursionDepth = 3, IgnoreInaccessible = true }))
                {
                    var rel = Path.GetRelativePath(dir, entry);
                    if (rel.Split(Path.DirectorySeparatorChar).Any(seg => seg.StartsWith('.'))) continue;
                    if (Directory.Exists(entry)) sb.AppendLine(rel + Path.DirectorySeparatorChar);
                    else sb.AppendLine($"{rel} ({new FileInfo(entry).Length} 字节)");
                    if (++count >= 300) { sb.AppendLine("…（已截断，超过 300 项）"); break; }
                }
                return sb.Length == 0 ? "（空目录）" : sb.ToString();
            }
            case "read_file":
            {
                var file = Resolve(path);
                if (path.Length == 0 || file is null) return "错误：路径无效或越界";
                if (!File.Exists(file)) return "错误：文件不存在或不可读";
                var info = new FileInfo(file);
                if (info.Length > 200_000) return $"错误：文件过大（{info.Length} 字节，上限 200KB）";
                try { return File.ReadAllText(file, Encoding.UTF8); }
                catch { return "错误：不是 UTF-8 文本文件"; }
            }
            case "write_file":
            {
                var requested = Resolve(path);
                if (path.Length == 0 || requested is null) return "错误：路径无效或越界";
                var content = (string?)input["content"];
                if (content is null) return "错误：缺少 content 参数";
                var overwrite = (bool?)input["overwrite"] ?? false;
                var directory = Path.GetDirectoryName(requested)!;
                Directory.CreateDirectory(directory);
                var temporary = Path.Combine(directory, $".folderis-{Guid.NewGuid():N}.tmp");
                try
                {
                    await File.WriteAllTextAsync(temporary, content, new UTF8Encoding(false), ct);
                    if (overwrite)
                    {
                        File.Move(temporary, requested, overwrite: true);
                        return $"已写入 {Path.GetFileName(requested)}（{Encoding.UTF8.GetByteCount(content)} 字节）";
                    }
                    for (var index = 1; index < 10_000; index++)
                    {
                        var candidate = OutputCandidate(requested, index);
                        try
                        {
                            File.Move(temporary, candidate, overwrite: false);
                            return $"已写入 {Path.GetFileName(candidate)}（{Encoding.UTF8.GetByteCount(content)} 字节）";
                        }
                        catch (IOException) when (File.Exists(candidate) || Directory.Exists(candidate))
                        {
                            // Another task claimed this name. Try the next suffix.
                        }
                    }
                    return "错误：无法生成不重复的文件名";
                }
                finally
                {
                    if (File.Exists(temporary)) File.Delete(temporary);
                }
            }
            case "edit_file":
            {
                var file = Resolve(path);
                if (path.Length == 0 || file is null) return "错误：路径无效或越界";
                if (!File.Exists(file)) return "错误：文件不存在";
                if ((bool?)input["overwrite"] != true)
                    return "错误：修改已有文件需要用户明确授权，并传 overwrite=true";
                var oldStr = (string?)input["old_string"] ?? "";
                var newStr = (string?)input["new_string"] ?? "";
                var all = (bool?)input["replace_all"] ?? false;
                if (oldStr.Length == 0) return "错误：old_string 不能为空";
                var text = await File.ReadAllTextAsync(file, ct);
                int occurrences = 0, idx = 0;
                while ((idx = text.IndexOf(oldStr, idx, StringComparison.Ordinal)) >= 0) { occurrences++; idx += oldStr.Length; }
                if (occurrences == 0) return "错误：old_string 在文件中未找到（须精确匹配，包括空白）";
                if (occurrences > 1 && !all) return $"错误：old_string 出现 {occurrences} 次，须唯一匹配（或用 replace_all）";
                text = text.Replace(oldStr, newStr);
                await File.WriteAllTextAsync(file, text, new UTF8Encoding(false), ct);
                return $"已替换 {(all ? occurrences : 1)} 处 → {path}";
            }
            case "move_file":
            case "copy_file":
            {
                var from = Resolve((string?)input["from"] ?? "");
                var to = Resolve((string?)input["to"] ?? "");
                if (from is null || to is null) return "错误：路径无效或越界";
                if (!File.Exists(from) && !Directory.Exists(from)) return "错误：源不存在";
                Directory.CreateDirectory(Path.GetDirectoryName(to)!);
                if (name == "move_file")
                {
                    if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to, overwrite: false);
                    return $"已移动 → {input["to"]}";
                }
                if (Directory.Exists(from)) CopyDir(from, to); else File.Copy(from, to, overwrite: false);
                return $"已复制 → {input["to"]}";
            }
            case "trash_file":
            {
                var file = Resolve(path);
                if (path.Length == 0 || file is null) return "错误：路径无效或越界";
                if (!File.Exists(file) && !Directory.Exists(file)) return "错误：目标不存在";
                // 系统回收站（可恢复），对齐 mac 的废纸篓语义
                NativeMethods.MoveToRecycleBin(file);
                return $"已移入回收站：{path}";
            }
            case "make_directory":
            {
                var dir = Resolve(path);
                if (path.Length == 0 || dir is null) return "错误：路径无效或越界";
                Directory.CreateDirectory(dir);
                return $"已创建目录 {path}";
            }
            case "search_files":
            {
                var pattern = (string?)input["pattern"] ?? "";
                if (pattern.Length == 0) return "错误：缺少 pattern";
                Regex re;
                try { re = new Regex(pattern, RegexOptions.None, TimeSpan.FromSeconds(2)); }
                catch (Exception e) { return $"错误：正则无效（{e.Message}）"; }
                var baseDir = Resolve(path.Length == 0 ? "." : path);
                if (baseDir is null) return "错误：路径越界";
                var sb = new StringBuilder();
                var hits = 0;
                foreach (var f in Directory.EnumerateFiles(baseDir, "*", new EnumerationOptions
                         { RecurseSubdirectories = true, MaxRecursionDepth = 5, IgnoreInaccessible = true }))
                {
                    if (new FileInfo(f).Length > 1_000_000) continue;
                    string[] fileLines;
                    try { fileLines = File.ReadAllLines(f); } catch { continue; }
                    for (var ln = 0; ln < fileLines.Length; ln++)
                    {
                        bool matched;
                        try { matched = re.IsMatch(fileLines[ln]); } catch (RegexMatchTimeoutException) { break; }
                        if (!matched) continue;
                        sb.AppendLine($"{Path.GetRelativePath(baseDir, f)}:{ln + 1}:{fileLines[ln].Trim()}");
                        if (++hits >= 200) return sb.AppendLine("…（已截断，超过 200 条）").ToString();
                    }
                }
                return hits == 0 ? "没有匹配" : sb.ToString();
            }
            case "run_command":
            {
                var command = (string?)input["command"] ?? "";
                if (command.Length == 0) return "错误：缺少 command 参数";
                var approved = ApprovalMode switch
                {
                    "yolo" => true,
                    "safeAuto" when IsReadOnly(command) => true,
                    _ => ApprovalHandler is null || await ApprovalHandler(command, (string?)input["purpose"])
                };
                if (!approved) return "用户拒绝执行该命令。请尊重用户决定，不要重复请求同一命令。";
                var psi = new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c " + command)
                {
                    WorkingDirectory = Root,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                using var proc = System.Diagnostics.Process.Start(psi)!;
                var so = proc.StandardOutput.ReadToEndAsync(ct);
                var se = proc.StandardError.ReadToEndAsync(ct);
                var done = proc.WaitForExitAsync(ct);
                if (await Task.WhenAny(done, Task.Delay(TimeSpan.FromMinutes(3), ct)) != done)
                {
                    try { proc.Kill(entireProcessTree: true); } catch { }
                    return "错误：命令超时（3 分钟）已终止";
                }
                var output = (await so) + (await se);
                if (output.Length > 20_000) output = output[..20_000] + "\n…（输出已截断）";
                return output.Length == 0 ? $"（无输出，退出码 {proc.ExitCode}）" : output;
            }
            default:
                return $"错误：未知工具 {name}";
        }
    }

    private static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)));
        foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
    }

    /// <summary>聊天区活动标签（移植 mac toolActivityLabel）。</summary>
    public static string ActivityLabel(string name, JsonObject input)
    {
        string S(string k) => (string?)input[k] ?? "";
        return name switch
        {
            "list_files" => $"🔍 浏览 {S("path")}",
            "read_file" => $"📖 读取 {S("path")}",
            "write_file" => $"✏️ 写入 {S("path")}",
            "edit_file" => $"🪛 编辑 {S("path")}",
            "move_file" => $"📛 移动 {S("from")} → {S("to")}",
            "copy_file" => $"📋 复制 {S("from")} → {S("to")}",
            "trash_file" => $"🗑️ 回收站 {S("path")}",
            "make_directory" => $"📁 新建目录 {S("path")}",
            "search_files" => $"🔎 搜索 {S("pattern")}",
            "run_command" => $"⚙️ 执行 {S("command")}",
            "run_skill" => $"🧰 技能 {S("skill")}",
            "spawn_subagent" => "🤖 子代理",
            _ => name
        };
    }
}
