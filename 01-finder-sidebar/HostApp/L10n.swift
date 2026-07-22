import Foundation

/// 轻量双语：中文系统显示中文，其余显示英文。
/// 环境变量 FOLDERIS_LANG=zh|en 可强制覆盖（测试/用户偏好用）。
enum L10n {
    static let isChinese: Bool = {
        if let forced = ProcessInfo.processInfo.environment["FOLDERIS_LANG"] {
            return forced.lowercased().hasPrefix("zh")
        }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }()
}

/// 用法：L("中文文案", "English copy")
@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    L10n.isChinese ? zh : en
}
