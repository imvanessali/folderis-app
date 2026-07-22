import Cocoa
import FinderSync

/// Reports which directories Finder is currently showing to the host app.
/// FinderSync only tells us which folders are *being observed* (visible in some
/// Finder window or the sidebar) — it does not give window frames, so the host
/// app cross-references this with Accessibility-derived window geometry.
final class FinderSync: FIFinderSync {

    private let distributedCenterName = "com.local.findersidebar.directoryChanged"

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func beginObservingDirectory(at url: URL) {
        postDirectoryEvent(url: url, isBeginning: true)
    }

    override func endObservingDirectory(at url: URL) {
        postDirectoryEvent(url: url, isBeginning: false)
    }

    private func postDirectoryEvent(url: URL, isBeginning: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(distributedCenterName),
            object: nil,
            userInfo: [
                "path": url.path,
                "event": isBeginning ? "begin" : "end"
            ],
            deliverImmediately: true
        )
    }

    override var toolbarItemName: String {
        "AI 助手"
    }

    override var toolbarItemToolTip: String {
        "在悬浮面板中与 AI 助手对话"
    }

    override var toolbarItemImage: NSImage {
        if let url = Bundle(for: FinderSync.self).url(forResource: "ToolbarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            return image
        }
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage()
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .toolbarItemMenu else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "显示/隐藏 AI 聊天面板", action: #selector(togglePanel), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func togglePanel() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.local.findersidebar.togglePanel"),
            object: nil,
            deliverImmediately: true
        )
    }
}
