import AppKit
import Sparkle
import SwiftUI

/// 无感升级:后台静默检查+下载,就绪后只在面板出温和横幅「重启生效」,
/// 全程不弹窗打断。用户点「立即重启」当场装,点「稍后」则退出时自动装。
/// 开发构建的 Info.plist 没有 SUFeedURL,更新器保持禁用,行为与从前一致。
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    /// 新版本已下载解压完毕,等待重启;nil 表示当前无待装更新。
    @Published private(set) var readyVersion: String?

    private var updater: SPUUpdater?
    private var driver: GentleUpdateDriver?
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?

    var isEnabled: Bool { updater != nil }
    var showsBanner: Bool { readyVersion != nil }

    func start() {
        guard updater == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            NSLog("updater: no SUFeedURL in Info.plist, auto-update disabled (dev build)")
            return
        }
        let driver = GentleUpdateDriver(manager: self)
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
        } catch {
            NSLog("updater: failed to start: %@", String(describing: error))
            return
        }
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        self.driver = driver
        self.updater = updater
    }

    /// 菜单栏「检查更新…」。用户主动发起,结果用弹窗反馈是合理打断。
    func checkForUpdatesManually() {
        guard let updater else { return }
        driver?.userInitiatedCheck = true
        updater.checkForUpdates()
    }

    func restartAndInstall() {
        guard let reply = pendingInstallReply else {
            // 更新会话已被 Sparkle 收回(罕见):收起横幅,静默重新检查恢复状态,
            // 避免出现「点了没反应」的死按钮。
            readyVersion = nil
            updater?.checkForUpdatesInBackground()
            return
        }
        pendingInstallReply = nil
        reply(.install)
    }

    /// 「稍后」:收起横幅,更新仍会在 App 退出时自动安装。若会话一直不退出,
    /// 下一个检查周期(24h)会温和地再次提醒——与 Windows 端「下次启动仍提示」同取向。
    func snoozeBanner() {
        readyVersion = nil
        guard let reply = pendingInstallReply else { return }
        pendingInstallReply = nil
        reply(.dismiss)
    }

    // MARK: - GentleUpdateDriver 回调

    fileprivate func updateReady(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingInstallReply = reply
        readyVersion = version
    }

    fileprivate func sessionDismissed() {
        // 会话结束后旧的 reply 已失效,横幅一并收起;下一轮检查会重新亮起。
        pendingInstallReply = nil
        readyVersion = nil
    }
}

/// 自定义 SPUUserDriver:把 Sparkle 的全部 UI 时机吞成静默,只在
/// 「更新就绪」这一个时刻通知 UpdaterManager 亮横幅。
@MainActor
private final class GentleUpdateDriver: NSObject, SPUUserDriver {
    private unowned let manager: UpdaterManager
    /// 本轮检查是否由用户从菜单发起(决定「没有更新/出错」要不要弹窗告知)。
    var userInitiatedCheck = false
    /// 最近一次在 appcast 里发现的版本号,用于横幅文案。
    private var lastFoundVersion = ""

    init(manager: UpdaterManager) {
        self.manager = manager
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // 产品决策:默认自动检查+下载,不向用户弹权限询问,也不回传系统信息。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        lastFoundVersion = appcastItem.displayVersionString
        switch state.stage {
        case .downloaded:
            presentReady(version: appcastItem.displayVersionString, reply: reply)
        case .notDownloaded:
            // 静默下载(自动下载开启时通常不经过这里;手动检查会走到,
            // userInitiatedCheck 保持到下载就绪时再给用户明确反馈)。
            reply(.install)
        case .installing:
            reply(.dismiss)
        @unknown default:
            reply(.dismiss)
        }
    }

    /// 更新就绪的统一出口:后台检查走温和横幅;用户主动检查时给一个
    /// 明确的弹窗反馈(此刻横幅可能因 AI 任务进行中被抑制,不能没有下文)。
    private func presentReady(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard userInitiatedCheck else {
            manager.updateReady(version: version, reply: reply)
            return
        }
        userInitiatedCheck = false
        let alert = NSAlert()
        alert.messageText = L("新版本已就绪", "Update Ready")
        alert.informativeText = L(
            "新版本 \(version) 已下载完成，重启后生效。",
            "Version \(version) has been downloaded and will apply after a restart.")
        alert.addButton(withTitle: L("立即重启", "Restart Now"))
        alert.addButton(withTitle: L("稍后", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            reply(.install)
        } else {
            // 稍后 = 退出时自动安装,与横幅的「稍后」语义一致。
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if userInitiatedCheck {
            userInitiatedCheck = false
            let alert = NSAlert()
            alert.messageText = L("已是最新版本", "You're up to date")
            alert.informativeText = L(
                "当前运行的已经是最新版本的 Folderis。",
                "You are running the latest version of Folderis.")
            alert.runModal()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        NSLog("updater: error: %@", String(describing: error))
        if userInitiatedCheck {
            userInitiatedCheck = false
            let alert = NSAlert()
            alert.messageText = L("检查更新失败", "Update Check Failed")
            alert.informativeText = (error as NSError).localizedDescription
            alert.runModal()
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        presentReady(
            version: lastFoundVersion.isEmpty
                ? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "")
                : lastFoundVersion,
            reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        manager.sessionDismissed()
    }
}

/// 面板顶部的温和更新横幅:不抢焦点、不弹窗,一行文案 + 两个轻按钮。
struct UpdateReadyBanner: View {
    let version: String
    let onRestart: () -> Void
    let onLater: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.tint)
            Text(L("新版本 \(version) 已就绪，重启后生效",
                   "Version \(version) is ready — restart to apply"))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(L("立即重启", "Restart Now"), action: onRestart)
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
        .background(Color.accentColor.opacity(0.08))
    }
}
