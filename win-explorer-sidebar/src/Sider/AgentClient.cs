using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sider;

/// <summary>
/// 最小代理客户端：通过 DeepSeek 的 OpenAI 兼容协议进行 SSE 流式调用，
/// 内置一个 run_skill 工具（复用与 macOS 版完全相同的 Python 技能库）。
/// Anthropic 协议与完整文件工具组照 macOS 版逐一移植（见 README 状态表）。
/// </summary>
public sealed class AgentClient(Settings settings, SkillRunner skills, FileTools fileTools)
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    private const int CompactBudget = 48_000;

    /// <summary>历史超预算时压缩较早消息为摘要（对齐 mac compactIfNeeded）。</summary>
    public async Task CompactIfNeededAsync(List<JsonObject> history, CancellationToken ct)
    {
        var total = history.Sum(m => ((string?)m["content"])?.Length ?? 0);
        if (total <= CompactBudget || history.Count <= 8) return;
        var keep = history.Skip(history.Count - 6).ToList();
        var older = history.Take(history.Count - 6)
            .Where(m => m["tool_calls"] is null && (string?)m["role"] is "user" or "assistant")
            .Select(m => $"{((string?)m["role"] == "user" ? "用户" : "助手")}：{(string?)m["content"]}");
        var transcript = string.Join("\n\n", older);
        if (transcript.Length > 60_000) transcript = transcript[..60_000];
        var summary = await OneShotAsync(
            "请把下面这段助手与用户的对话压缩成简洁的要点摘要（跟随对话语言），保留关键事实、已做的操作、涉及的文件和未决事项：\n\n" + transcript, ct);
        history.Clear();
        history.Add(new JsonObject { ["role"] = "assistant",
            ["content"] = "（之前对话的摘要）\n" + summary });
        history.AddRange(keep);
    }

    /// <summary>非流式单轮调用（压缩摘要用）。</summary>
    private async Task<string> OneShotAsync(string prompt, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
        http.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", settings.ApiKey);
        var body = new JsonObject
        {
            ["model"] = settings.Model,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = prompt })
        };
        var resp = await http.PostAsync(settings.BaseUrl,
            new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json"), ct);
        var json = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct))!;
        return (string?)json["choices"]?[0]?["message"]?["content"] ?? "（摘要为空）";
    }

    public async Task RunAsync(
        List<JsonObject> history,
        string systemPrompt,
        Action<string> onDelta,
        Action<string> onActivity,
        CancellationToken ct,
        bool allowTools = true,
        string? taskId = null)
    {
        var messages = new JsonArray(
            new JsonObject { ["role"] = "system", ["content"] = systemPrompt });
        foreach (var m in history)
        {
            var role = (string?)m["role"] ?? "user";
            var content = (string?)m["content"] ?? "";
            if (role == "user" && (string?)m["taskId"] is { Length: > 0 } messageTaskId)
                content = $"任务编号：{messageTaskId}\n\n{content}";
            // Local metadata is persisted beside the message, but provider
            // APIs reject unknown fields such as taskId.
            messages.Add(new JsonObject { ["role"] = role, ["content"] = content });
        }

        string lastFailSig = ""; var failStreak = 0; var emptyRetryUsed = false;
        var completedToolCalls = new Dictionary<string, string>(StringComparer.Ordinal);

        for (var round = 0; round < 40; round++)
        {
            ct.ThrowIfCancellationRequested();
            var (text, toolCalls, _) = await StreamOnceAsync(messages, onDelta, ct, allowTools);

            if (toolCalls.Count == 0)
            {
                if (!string.IsNullOrWhiteSpace(text)) return;
                if (emptyRetryUsed)
                {
                    onDelta(L10n.T("DeepSeek 连续返回空内容，请重试本条消息。",
                                   "DeepSeek returned empty output twice; please retry."));
                    return;
                }
                emptyRetryUsed = true;
                messages.Add(new JsonObject
                {
                    ["role"] = "user",
                    ["content"] = "[系统] 上一轮模型没有返回任何文字或工具调用。请继续当前任务；如果无法完成，请明确说明原因，不要返回空内容。"
                });
                continue;
            }

            var assistant = new JsonObject
            {
                ["role"] = "assistant",
                ["tool_calls"] = new JsonArray(toolCalls.Select(t => (JsonNode)new JsonObject
                {
                    ["id"] = t.Id,
                    ["type"] = "function",
                    ["function"] = new JsonObject { ["name"] = t.Name, ["arguments"] = t.Arguments }
                }).ToArray())
            };
            if (text.Length > 0) assistant["content"] = text;
            messages.Add(assistant);

            foreach (var call in toolCalls)
            {
                JsonObject actArgs;
                try { actArgs = JsonNode.Parse(call.Arguments)!.AsObject(); } catch { actArgs = new JsonObject(); }
                onActivity(FileTools.ActivityLabel(call.Name, actArgs));
                var callSignature = call.Name + "\n" + call.Arguments;
                string output;
                if (completedToolCalls.TryGetValue(callSignature, out var previousOutput))
                {
                    output = L10n.T(
                        "[系统] 完全相同的操作已在本次请求中成功执行，未重复运行。之前的结果：\n" + previousOutput,
                        "[system] The identical operation already succeeded in this request and was not run again. Previous result:\n" + previousOutput);
                }
                else
                {
                    output = await ExecuteToolAsync(call, ct);
                }
                // 熔断：同一调用连续同错 3 次，不再让模型继续磨
                var failed = output.Contains("错误") || output.Contains("Error") || output.Contains("失败");
                if (!failed && !completedToolCalls.ContainsKey(callSignature))
                    completedToolCalls[callSignature] = output;
                var sig = call.Name + "|" + call.Arguments + "|" + output[..Math.Min(120, output.Length)];
                if (failed && sig == lastFailSig)
                {
                    if (++failStreak >= 3)
                        output += L10n.T(
                            "\n\n[系统] 同一操作已连续失败 3 次，请停止重试，把失败原因如实告知用户并请示下一步。",
                            "\n\n[system] Same operation failed 3 times in a row. Stop retrying; report the error to the user and ask how to proceed.");
                }
                else { lastFailSig = failed ? sig : ""; failStreak = failed ? 1 : 0; }
                messages.Add(new JsonObject
                {
                    ["role"] = "tool",
                    ["tool_call_id"] = call.Id,
                    ["content"] = output
                });
            }
        }
        var zhLabel = string.IsNullOrWhiteSpace(taskId) ? "" : $"任务 {taskId}：";
        var enLabel = string.IsNullOrWhiteSpace(taskId) ? "" : $"Task {taskId}: ";
        onDelta(L10n.T($"\n⚠️ {zhLabel}工具调用达到 40 轮上限，已停止。",
                       $"\n⚠️ {enLabel}tool calls reached the 40-round limit and stopped."));
    }

    /// <summary>子代理内禁用 run_command 与再派生（对齐 mac）。</summary>
    public bool IsSubagent { get; init; }

    private JsonArray BuildTools()
    {
        var tools = (JsonArray)SkillRunner.ToolSchema.DeepClone();
        foreach (var t in (JsonArray)FileTools.BuildSchema())
        {
            var name = (string?)t!["function"]?["name"];
            if (IsSubagent && name == "run_command") continue;
            tools.Add(t.DeepClone());
        }
        if (!IsSubagent)
        {
            tools.Add(new JsonObject
            {
                ["type"] = "function",
                ["function"] = new JsonObject
                {
                    ["name"] = "spawn_subagent",
                    ["description"] = "派生一个独立的子代理完成自包含的子任务。子代理有独立上下文和相同的文件工具（但不能执行命令或再派生），只把最终结论返回给你。",
                    ["parameters"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["properties"] = new JsonObject
                        {
                            ["task"] = new JsonObject { ["type"] = "string",
                                ["description"] = "交给子代理的完整任务描述，必须自包含" }
                        },
                        ["required"] = new JsonArray("task")
                    }
                }
            });
        }
        return tools;
    }

    private async Task<string> ExecuteToolAsync(ToolCall call, CancellationToken ct)
    {
        JsonObject args;
        try { args = JsonNode.Parse(call.Arguments)!.AsObject(); }
        catch { return "错误：工具参数不是合法 JSON"; }
        try
        {
            if (call.Name == "run_skill")
            {
                var skill = (string?)args["skill"] ?? "";
                var skillArgs = (args["args"] as JsonArray)?
                    .Select(n => (string?)n ?? "").ToArray() ?? [];
                var cwd = (string?)args["cwd"] ?? fileTools.Root ?? Environment.CurrentDirectory;
                return await skills.RunAsync(skill, skillArgs, cwd, ct);
            }
            if (call.Name == "spawn_subagent")
            {
                if (IsSubagent) return "错误：子代理不能再派生子代理";
                var task = (string?)args["task"] ?? "";
                if (task.Length == 0) return "错误：缺少 task 参数";
                var sub = new AgentClient(settings, skills, fileTools) { IsSubagent = true };
                var subHistory = new List<JsonObject>
                {
                    new() { ["role"] = "user", ["content"] = task }
                };
                var result = new System.Text.StringBuilder();
                await sub.RunAsync(subHistory,
                    $"你是一个子代理，独立完成给定任务后输出最终结论。工作目录：{fileTools.Root ?? "无"}。",
                    onDelta: d => result.Append(d), onActivity: _ => { }, ct);
                var text = result.ToString();
                return text.Length == 0 ? "（子代理无输出）"
                     : text.Length > 8000 ? text[..8000] + "\n…（已截断）" : text;
            }
            if (FileTools.ToolNames.Contains(call.Name))
                return await fileTools.ExecuteAsync(call.Name, args, ct);
            return L10n.T($"未知工具 {call.Name}", $"Unknown tool {call.Name}");
        }
        catch (Exception e)
        {
            return L10n.T($"工具执行失败：{e.Message}", $"Tool failed: {e.Message}");
        }
    }

    private sealed record ToolCall(string Id, string Name, string Arguments);

    private async Task<(string Text, List<ToolCall> Calls, string? Finish)> StreamOnceAsync(
        JsonArray messages, Action<string> onDelta, CancellationToken ct, bool allowTools)
    {
        var body = new JsonObject
        {
            ["model"] = settings.Model,
            ["stream"] = true,
            ["messages"] = messages.DeepClone()
        };
        if (allowTools) body["tools"] = BuildTools();

        using var req = new HttpRequestMessage(HttpMethod.Post, settings.BaseUrl)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json")
        };
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {settings.ApiKey}");

        using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var err = await resp.Content.ReadAsStringAsync(ct);
            throw new HttpRequestException($"HTTP {(int)resp.StatusCode}: {err[..Math.Min(300, err.Length)]}");
        }

        var text = new StringBuilder();
        var calls = new Dictionary<int, (string Id, string Name, StringBuilder Args)>();
        string? finish = null;

        using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);
        while (await reader.ReadLineAsync(ct) is { } line)
        {
            if (!line.StartsWith("data:")) continue;
            var payload = line[5..].Trim();
            if (payload == "[DONE]") break;

            JsonNode? node;
            try { node = JsonNode.Parse(payload); } catch { continue; }
            var choice = node?["choices"]?[0];
            if (choice is null) continue;

            if ((string?)choice["finish_reason"] is { } fr) finish = fr;

            var delta = choice["delta"];
            if ((string?)delta?["content"] is { } t)
            {
                text.Append(t);
                onDelta(t);
            }
            if (delta?["tool_calls"] is JsonArray tcs)
            {
                foreach (var tc in tcs)
                {
                    var index = (int?)tc?["index"] ?? 0;
                    var entry = calls.TryGetValue(index, out var e) ? e : ("", "", new StringBuilder());
                    if ((string?)tc?["id"] is { } id) entry.Item1 = id;
                    if ((string?)tc?["function"]?["name"] is { } name) entry.Item2 += name;
                    if ((string?)tc?["function"]?["arguments"] is { } args) entry.Item3.Append(args);
                    calls[index] = entry;
                }
            }
        }

        var ordered = calls.OrderBy(kv => kv.Key)
            .Select(kv => new ToolCall(kv.Value.Id, kv.Value.Name, kv.Value.Args.ToString()))
            .ToList();
        return (text.ToString(), ordered, finish);
    }
}
