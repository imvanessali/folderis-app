import Cocoa
import SwiftUI
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var chat = ChatViewModel(settings: settings)
    private let finderContext = FinderContext()
    private let tracker = FinderWindowTracker()
    private var panelController: FloatingPanelController?
    private var finderServicesStarted = false
    private var instanceLockFD: Int32 = -1

    private let toggleNotificationName = NSNotification.Name("com.local.findersidebar.togglePanel")

    nonisolated private static func marker(_ name: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Copies a runtime directory to staging, then swaps it into place. If the
    /// swap fails, the previous working directory is restored.
    nonisolated private static func replaceRuntimeDirectory(
        _ name: String, bundled: URL, support: URL
    ) throws {
        let fm = FileManager.default
        let source = bundled.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let token = UUID().uuidString
        let staging = support.appendingPathComponent(".\(name).installing-\(token)", isDirectory: true)
        let backup = support.appendingPathComponent(".\(name).backup-\(token)", isDirectory: true)
        let destination = support.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: source, to: staging)

        var movedPrevious = false
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: backup)
                movedPrevious = true
            }
            try fm.moveItem(at: staging, to: destination)
            if movedPrevious { try? fm.removeItem(at: backup) }
        } catch {
            try? fm.removeItem(at: staging)
            if movedPrevious && !fm.fileExists(atPath: destination.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    /// Skills are small and feed a process-wide static catalog, so update them
    /// synchronously before the chat model is created. This prevents an updated
    /// app from loading stale scripts or catalog text for the whole session.
    nonisolated private static func installBundledSkillsIfNeeded() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
              FileManager.default.fileExists(atPath: bundled.path) else {
            NSLog("skills-install: no bundled runtime")
            return
        }
        let support = ChatViewModel.supportRoot
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let bundledVersion = try Self.marker("SKILLS_VERSION", in: bundled)
            let markerURL = support.appendingPathComponent("SKILLS_VERSION")
            let installedVersion = (try? Self.marker("SKILLS_VERSION", in: support)) ?? ""
            let bundledScript = bundled.appendingPathComponent("skills/skills.py")
            let bundledCatalog = bundled.appendingPathComponent("skills/catalog.txt")
            let installedScript = support.appendingPathComponent("skills/skills.py")
            let installedCatalog = support.appendingPathComponent("skills/catalog.txt")
            guard bundledVersion != installedVersion ||
                    !FileManager.default.contentsEqual(
                        atPath: bundledScript.path, andPath: installedScript.path) ||
                    !FileManager.default.contentsEqual(
                        atPath: bundledCatalog.path, andPath: installedCatalog.path) else {
                NSLog("skills-install: up to date (%@)", installedVersion)
                return
            }
            try Self.replaceRuntimeDirectory("skills", bundled: bundled, support: support)
            try bundledVersion.write(to: markerURL, atomically: true, encoding: .utf8)
            NSLog("skills-install: installed %@ (was: %@)", bundledVersion, installedVersion)
        } catch {
            NSLog("skills-install: failed: %@", String(describing: error))
        }
    }

    /// The large Python and binary runtime updates in the background. Skills
    /// use their own content marker and are never overwritten by this path.
    nonisolated private static func installBundledRuntimeIfNeeded() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
              FileManager.default.fileExists(atPath: bundled.path) else {
            NSLog("runtime-install: no bundled runtime")
            return
        }
        let support = ChatViewModel.supportRoot
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let bundledVersion = try Self.marker("VERSION", in: bundled)
            let markerURL = support.appendingPathComponent("RUNTIME_VERSION")
            let installedVersion = (try? Self.marker("RUNTIME_VERSION", in: support)) ?? ""
            let installedPython = support.appendingPathComponent("python/bin/python3")
            guard bundledVersion != installedVersion ||
                    !FileManager.default.fileExists(atPath: installedPython.path) else {
                NSLog("runtime-install: up to date (%@)", installedVersion)
                return
            }
            for item in ["python", "bin"] {
                try Self.replaceRuntimeDirectory(item, bundled: bundled, support: support)
            }
            try bundledVersion.write(to: markerURL, atomically: true, encoding: .utf8)
            NSLog("runtime-install: installed %@ (was: %@)", bundledVersion, installedVersion)
        } catch {
            NSLog("runtime-install: failed: %@", String(describing: error))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        // The catalog is loaded once, so skills must be current before chat is created.
        Self.installBundledSkillsIfNeeded()
        // 首启运行时安装含 ~180MB 拷贝，放后台避免卡住界面。
        DispatchQueue.global(qos: .utility).async {
            Self.installBundledRuntimeIfNeeded()
        }
        // Menu-bar-only presence; the real UI lives in the floating panel docked to Finder.
        NSApp.setActivationPolicy(.accessory)

        panelController = FloatingPanelController(
            settings: settings,
            chat: chat,
            finderContext: finderContext,
            tracker: tracker
        )
        if !Onboarding.needed {
            startFinderServices()
        }
        panelController?.show()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleToggle),
            name: toggleNotificationName,
            object: nil
        )

        installEditMenu()
        setupStatusItem()

        if Onboarding.needed {
            showOnboarding()
        }
    }

    // MARK: - Onboarding（首次启动引导）

    private var onboardingWindow: NSWindow?

    private func showOnboarding() {
        let view = OnboardingView(settings: settings) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.startFinderServices()
        }
        let hosting = NSHostingController(rootView: view)
        // 无边框 + 自绘圆角（同面板做法）：一开始就以 borderless 创建，
        // 事后改 styleMask 会留下标题栏玻璃残影。
        let window = OnboardingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // 面板本身是 .floating，引导要压在它上面。
        window.level = .modalPanel
        onboardingWindow = window
        window.setContentSize(NSSize(width: 520, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finder tracking sends permission-sensitive AX and Apple Events requests.
    /// Keep both services stopped until onboarding reaches and completes its
    /// permissions flow so no system consent dialog covers an earlier page.
    private func startFinderServices() {
        guard !finderServicesStarted else { return }
        finderServicesStarted = true
        tracker.start()
        finderContext.start()
    }

    /// Accessory apps have no menu bar, so the standard Cmd+X/C/V/A shortcuts
    /// (which are delivered via Edit-menu key equivalents) don't reach text
    /// fields. Install a minimal main menu with an Edit menu to restore them.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L("编辑", "Edit"))
        editMenu.addItem(withTitle: L("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.stop()
        finderContext.stop()
        if instanceLockFD >= 0 {
            flock(instanceLockFD, LOCK_UN)
            close(instanceLockFD)
            instanceLockFD = -1
        }
    }

    /// SwiftPM and Xcode builds can coexist during development. A shared
    /// lock ensures they still produce only one panel.
    private func acquireSingleInstanceLock() -> Bool {
        let edition = "full"
        let path = NSTemporaryDirectory() + "com.local.findersidebar.\(edition).\(getuid()).lock"
        let fd = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    @objc private func handleToggle() {
        panelController?.toggle()
    }

    @objc private func clearConversation() {
        chat.clearConversation()
    }

    @objc private func openUserGuide() {
        let name = L10n.isChinese ? "使用手册" : "User Guide"
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Status item (menu bar icon as a manual show/hide + quit affordance)

    private var statusItem: NSStatusItem?

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.brandStatusImage()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("显示/隐藏聊天面板", "Show/Hide Panel"), action: #selector(handleToggle), keyEquivalent: "").also {
            $0.target = self
        })
        menu.addItem(NSMenuItem(title: L("清空对话", "Clear Conversation"), action: #selector(clearConversation), keyEquivalent: "").also {
            $0.target = self
        })
        menu.addItem(NSMenuItem(title: L("使用手册", "User Guide"), action: #selector(openUserGuide), keyEquivalent: "").also {
            $0.target = self
        })
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshStatusImage),
            name: BrandLogo.changedNotification, object: nil
        )
    }

    @objc private func refreshStatusImage() {
        statusItem?.button?.image = Self.brandStatusImage()
    }

    private static func brandStatusImage() -> NSImage {
        let image = BrandLogo.image(choice: BrandLogo.savedChoice)
            ?? NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Folderis")
            ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }
}

private extension NSMenuItem {
    func also(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}

/// Borderless windows refuse key status by default; the onboarding window
/// needs it so the API-key field can take typing.
private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
