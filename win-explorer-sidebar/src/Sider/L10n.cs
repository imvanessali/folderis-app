using System.Globalization;

namespace Sider;

/// <summary>轻量双语：中文环境显示中文，其余英文；FOLDERIS_LANG=zh|en 可强制。</summary>
public static class L10n
{
    public static readonly bool IsChinese = Init();

    private static bool Init()
    {
        var forced = Environment.GetEnvironmentVariable("FOLDERIS_LANG");
        if (!string.IsNullOrEmpty(forced))
            return forced.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
        return CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
    }

    public static string T(string zh, string en) => IsChinese ? zh : en;
}
