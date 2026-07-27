using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Sider;

/// <summary>
/// 配置存储：Key 用 DPAPI（当前用户）加密落盘——Windows 上等价于
/// macOS 钥匙串的定位；其余明文 JSON。
/// </summary>
public sealed class Settings
{
    public const string DeepSeekBaseUrl = "https://api.deepseek.com/chat/completions";
    public const string DeepSeekModel = "deepseek-v4-flash";
    public string BaseUrl { get; set; } = DeepSeekBaseUrl;
    public string Model { get; set; } = DeepSeekModel;
    public string ApiKey { get; set; } = "";
    public string Backend { get; set; } = "BuiltinApi"; // BuiltinApi | ClaudeCode | Codex | Cursor
    public bool OnboardingDone { get; set; }
    public string ApprovalMode { get; set; } = "safeAuto"; // ask | safeAuto | yolo

    private static string Dir => SkillRunner.SupportRoot;
    private static string ConfigPath => Path.Combine(Dir, "settings.json");
    private static string KeyPath => Path.Combine(Dir, "apikey.bin");

    public static Settings Load()
    {
        var s = new Settings();
        try
        {
            if (File.Exists(ConfigPath))
            {
                var json = JsonSerializer.Deserialize<Settings>(File.ReadAllText(ConfigPath));
                if (json is not null)
                {
                    s.Backend = json.Backend; s.OnboardingDone = json.OnboardingDone;
                    s.ApprovalMode = json.ApprovalMode;
                }
            }
            if (File.Exists(KeyPath) && OperatingSystem.IsWindows())
            {
                var blob = File.ReadAllBytes(KeyPath);
                s.ApiKey = Encoding.UTF8.GetString(
                    ProtectedData.Unprotect(blob, null, DataProtectionScope.CurrentUser));
            }
        }
        catch { /* 损坏配置按空处理 */ }
        // API 路径固定为 DeepSeek；另开放 CLI 后端。
        s.BaseUrl = DeepSeekBaseUrl;
        s.Model = DeepSeekModel;
        return s;
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(ConfigPath, JsonSerializer.Serialize(
            new { BaseUrl, Model, Backend, OnboardingDone, ApprovalMode },
            new JsonSerializerOptions { WriteIndented = true }));
        if (OperatingSystem.IsWindows())
        {
            var blob = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(ApiKey), null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(KeyPath, blob);
        }
    }
}
