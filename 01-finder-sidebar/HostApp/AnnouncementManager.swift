import AppKit
import SwiftUI

/// 版本公告(轻量更新提示):启动后静默拉取 announce.json,发现比本机新的
/// 版本就在面板顶部出横幅「前往下载」,点击打开发布页网页。不下载、不安装、
/// 无签名验签——下发内容完全由发布者改 JSON 控制,撤回即恢复安静。
/// 「稍后」在该版本内不再提醒(记 UserDefaults,更新版本号后会再次亮起)。
@MainActor
final class AnnouncementManager: ObservableObject {
    static let shared = AnnouncementManager()

    struct Notice: Equatable {
        let version: String
        let page: URL
        /// 发布者自定义文案(announce.json 的 message.zh/en),空则用默认文案。
        let message: String?
    }

    @Published private(set) var notice: Notice?

    /// 公告地址:Cloudflare Worker 静态托管,FOLDERIS_ANNOUNCE_URL 可覆盖(测试用)。
    static let defaultFeed = "https://folderis-announce.folderis.workers.dev/announce.json"
    private static let dismissedKey = "announceDismissedVersion"
    private static let startupDelay: UInt64 = 20 * 1_000_000_000
    private static let checkInterval: UInt64 = 24 * 3600 * 1_000_000_000
    /// 面板唤起补查的节流窗口：请求本身极廉价（静态 JSON），节流只为
    /// 不随 reposition 高频触发。
    private static let staleAfter: TimeInterval = 3600

    private var loop: Task<Void, Never>?
    private var lastCheckAt: Date?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.startupDelay)
            while !Task.isCancelled {
                // 循环同样尊重节流窗：面板唤起若刚补查过（如启动 20s 内
                // 面板已上屏），这一轮直接跳过，避免启动期双请求。
                await self?.checkOnceIfStale()
                try? await Task.sleep(nanoseconds: Self.checkInterval)
            }
        }
    }

    /// 面板唤起时的节流补查：用户真正看面板的时刻才是展示公告的时机，
    /// 24 小时定时器只是兜底。距上次检查不足 1 小时直接跳过。
    func checkIfStale() {
        guard loop != nil else { return }  // start() 之前无操作（与 Windows 对齐）
        guard Date().timeIntervalSince(lastCheckAt ?? .distantPast) >= Self.staleAfter else { return }
        lastCheckAt = Date()
        Task { [weak self] in await self?.checkOnce() }
    }

    private func checkOnceIfStale() async {
        guard Date().timeIntervalSince(lastCheckAt ?? .distantPast) >= Self.staleAfter else { return }
        await checkOnce()
    }

    func openDownloadPage() {
        guard let notice else { return }
        NSWorkspace.shared.open(notice.page)
    }

    /// 「稍后」:本版本内(含重启)不再提醒;下发更新的版本号后重新亮起。
    func dismiss() {
        guard let notice else { return }
        UserDefaults.standard.set(notice.version, forKey: Self.dismissedKey)
        self.notice = nil
    }

    private func checkOnce() async {
        lastCheckAt = Date()
        let feed = ProcessInfo.processInfo.environment["FOLDERIS_ANNOUNCE_URL"]
            ?? Self.defaultFeed
        guard let url = URL(string: feed) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mac = root["mac"] as? [String: Any],
              let version = (mac["version"] as? String)?
                  .trimmingCharacters(in: .whitespaces), !version.isEmpty,
              let pageString = (mac["url"] as? String)?
                  .trimmingCharacters(in: .whitespaces),
              let page = URL(string: pageString), pageString.hasPrefix("https://")
        else { return }  // 断网/格式错:静默保持现状,等下一轮

        // 与构建号比对(CFBundleVersion,如 20260727.4)——announce.json 的
        // version 用同一格式;营销版本号(1.1.0)不参与比较。
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "0"
        guard Self.isNewer(version, than: current),
              UserDefaults.standard.string(forKey: Self.dismissedKey) != version
        else {
            notice = nil  // 公告被撤回/已是最新:收起可能还亮着的横幅
            return
        }
        let messages = root["message"] as? [String: Any]
        let message = (messages?[L10n.isChinese ? "zh" : "en"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        notice = Notice(
            version: version, page: page,
            message: (message?.isEmpty ?? true) ? nil : message)
    }

    /// 按 "." 分段数值比较(20260730.1 > 20260727.4),缺段补零。
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// 面板顶部的版本公告横幅:与更新就绪横幅同风格,动作是打开下载网页。
struct AnnouncementBanner: View {
    let notice: AnnouncementManager.Notice
    let onDownload: () -> Void
    let onLater: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(notice.message
                 ?? L("新版本 \(notice.version) 已发布",
                      "Version \(notice.version) is available"))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(L("前往下载", "Download"), action: onDownload)
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(L("稍后", "Later"), action: onLater)
                .font(.caption)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // 浅黄底：公告要一眼可见，强调色淡蓝底和面板底色太接近。
        // 用系统 yellow 加低透明度，深色模式下自动变成暗琥珀色调。
        .background(Color.yellow.opacity(0.18))
    }
}
