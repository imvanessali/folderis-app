import Cocoa
import SwiftUI
import Combine

/// A non-activating panel that docks itself to the left edge of the frontmost
/// Finder window, repositioning whenever Finder moves/resizes. This is the
/// closest approximation of an "embedded Finder sidebar" possible without
/// private APIs: two separate windows kept visually glued together.
/// Borderless so there is no title bar, no traffic-light buttons, and no
/// draggable chrome; overrides canBecomeKey so text input still works.
private final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The collapsed state: a small floating circle the user clicks to re-open
/// the panel. Shows the current provider's mark. Docks near the top-right of
/// the Finder window.
private struct OrbView: View {
    @ObservedObject var settings: AppSettings
    let onTap: () -> Void

    /// Visible circle diameter.
    static let size: CGFloat = 44
    /// Transparent margin so the diffuse shadow isn't clipped by the window
    /// bounds (the clipped shadow read as a "square" artifact).
    static let padding: CGFloat = 16
    static var total: CGFloat { size + padding * 2 }

    var body: some View {
        Button(action: onTap) {
            orbFace
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 9, y: 2.5)
        }
        .buttonStyle(.plain)
        .frame(width: Self.total, height: Self.total)
        .help(L("展开 Folderis", "Expand Folderis"))
    }

    /// 悬浮球用品牌 logo（发布包内 OrbLogo.png）；开发构建无资源时退回符号样式。
    private var orbFace: some View {
        ZStack {
            Circle().fill(Color(nsColor: .controlBackgroundColor))
            if let url = Bundle.main.url(forResource: "OrbLogo", withExtension: "png"),
               let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                fallbackIcon
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(Circle())
    }

    private var fallbackIcon: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 18))
            .foregroundStyle(Color.accentColor)
    }
}

@MainActor
final class FloatingPanelController: NSObject {
    private let panel: NSPanel
    private let orbPanel: NSPanel
    private let tracker: FinderWindowTracker
    private let chat: ChatViewModel
    private let finderContext: FinderContext
    private var cancellables: Set<AnyCancellable> = []
    private var isCollapsed = false

    static let panelWidth: CGFloat = 320

    init(settings: AppSettings, chat: ChatViewModel, finderContext: FinderContext, tracker: FinderWindowTracker) {
        self.tracker = tracker
        self.chat = chat
        self.finderContext = finderContext

        // Borderless with a hand-drawn header: NSToolbar can only render its
        // buttons in the gray "inactive" style while Finder keeps focus, so
        // native-looking floating glass buttons must be drawn by us.
        panel = SidebarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 600),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Keep the panel at the normal window level. Its precise position in
        // Finder's z-order is maintained relative to the attached Finder
        // window, so another Finder window can correctly cover both of them.
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // The collapsed orb: a small transparent borderless panel (window is
        // larger than the circle so the shadow isn't clipped square).
        orbPanel = SidebarPanel(
            contentRect: NSRect(x: 0, y: 0, width: OrbView.total, height: OrbView.total),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        orbPanel.isFloatingPanel = true
        orbPanel.level = .normal
        orbPanel.hidesOnDeactivate = false
        orbPanel.isOpaque = false
        orbPanel.backgroundColor = .clear
        orbPanel.hasShadow = false
        orbPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init()

        orbPanel.contentView = NSHostingView(
            rootView: OrbView(settings: settings, onTap: { [weak self] in self?.expand() })
        )

        let content = SidebarPanelView(
            chat: chat,
            finderContext: finderContext,
            tracker: tracker,
            onCollapse: { [weak self] in self?.collapse() }
        )
        .environmentObject(settings)
        panel.contentView = NSHostingView(rootView: content)

        tracker.$frontmostFinderWindowFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.reposition(relativeTo: frame)
            }
            .store(in: &cancellables)
    }

    private func collapse() {
        isCollapsed = true
        panel.orderOut(nil)
        reposition(relativeTo: tracker.frontmostFinderWindowFrame)
    }

    private func expand() {
        isCollapsed = false
        orbPanel.orderOut(nil)
        reposition(relativeTo: tracker.frontmostFinderWindowFrame)
    }

    /// The user's intent (menu-bar/finder-toolbar toggle). The panel is only
    /// actually on screen when this is true AND Finder is the active app.
    private var userWantsPanel = true

    func show() {
        userWantsPanel = true
        reposition(relativeTo: tracker.frontmostFinderWindowFrame)
    }

    func hide() {
        userWantsPanel = false
        panel.orderOut(nil)
    }

    func toggle() {
        userWantsPanel ? hide() : show()
    }

    /// Minimum width Finder is allowed to keep when we squeeze it.
    private static let minFinderWidth: CGFloat = 480

    private func reposition(relativeTo finderFrame: CGRect?) {
        // Only accompany Finder: any other app frontmost → everything hides.
        guard userWantsPanel, tracker.isFinderFrontmost else {
            panel.orderOut(nil)
            orbPanel.orderOut(nil)
            return
        }

        // 安装镜像（只读卷）的访达窗口不贴面板：安装页不需要 AI 助手。
        if let folder = finderContext.currentFolder,
           let ro = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly,
           ro {
            panel.orderOut(nil)
            orbPanel.orderOut(nil)
            return
        }

        // Collapsed: show only the orb, docked to Finder's top-right corner.
        if isCollapsed {
            panel.orderOut(nil)
            guard let finderFrame else {
                orbPanel.orderOut(nil)
                return
            }
            let inset: CGFloat = 12
            // 从顶部多让出一段：避开 Finder 工具栏和搜索框区域。
            let topClearance: CGFloat = 76
            // 窗口比可见圆大一圈（阴影留白），坐标补偿 padding 保持圆的视觉位置。
            let orbFrame = NSRect(
                x: finderFrame.maxX - OrbView.size - inset - OrbView.padding,
                y: finderFrame.maxY - OrbView.size - topClearance - OrbView.padding,
                width: OrbView.total,
                height: OrbView.total
            )
            orbPanel.setFrame(orbFrame, display: true)
            orderDirectlyAboveFinder(orbPanel)
            return
        }
        orbPanel.orderOut(nil)

        // Finder is active but we can't get its window frame. If that's
        // because Accessibility isn't granted yet, park at the screen's right
        // edge so the permission guidance stays visible; if it's simply that
        // no Finder window is open (desktop click), hide.
        guard let finderFrame else {
            // 只有“确实有 Finder 窗口在屏，但因未授权拿不到位置”时才停靠：
            // 点桌面这类没有窗口的激活不该把面板弹出来。
            guard !tracker.accessibilityGranted, tracker.finderHasOnScreenWindow() else {
                panel.orderOut(nil)
                return
            }
            if let visible = NSScreen.main?.visibleFrame {
                let parked = NSRect(
                    x: visible.maxX - Self.panelWidth,
                    y: visible.minY,
                    width: Self.panelWidth,
                    height: visible.height
                )
                panel.setFrame(parked, display: true)
            }
            orderDirectlyAboveFinder(panel)
            return
        }

        let screen = NSScreen.screens.first { $0.frame.intersects(finderFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? finderFrame

        // "Squeeze" layout: the panel sits flush against Finder's right edge,
        // visually reading as part of the window. If there is no room on the
        // screen, shrink the Finder window itself so nothing is covered —
        // Finder reflows its icons, the panel takes the freed space.
        // Flush against Finder's right edge — no visible seam.
        let gap: CGFloat = 0

        var finder = finderFrame
        let overflow = (finder.maxX + gap + Self.panelWidth) - visible.maxX
        if overflow > 2 {
            let newWidth = max(Self.minFinderWidth, finder.width - overflow)
            var newX = finder.minX
            if finder.minX + newWidth + gap + Self.panelWidth > visible.maxX {
                // Shrinking alone isn't enough (window too far right / too
                // narrow already): also slide the window left.
                newX = max(visible.minX, visible.maxX - Self.panelWidth - gap - newWidth)
            }
            if abs(newWidth - finder.width) > 2 || abs(newX - finder.minX) > 2 {
                finder = CGRect(x: newX, y: finder.minY, width: newWidth, height: finder.height)
                tracker.setFrontFinderWindowFrame(finder)
            }
        }

        // 完全镜像 Finder 窗口的纵向位置和高度：窗口拖出屏幕边缘时，
        // 面板也跟着出去（"钉在窗口上"，而不是被屏幕边缘拦下）。
        let panelFrame = NSRect(
            x: finder.maxX + gap,
            y: finder.minY,
            width: Self.panelWidth,
            height: finder.height
        )
        panel.setFrame(panelFrame, display: true)
        orderDirectlyAboveFinder(panel)
    }

    /// Keep our normal-level window paired with the Finder window it is
    /// visually attached to. Ordering on every poll also handles switching
    /// between overlapping Finder windows whose frames happen to be equal.
    private func orderDirectlyAboveFinder(_ window: NSWindow) {
        if let finderWindowNumber = tracker.frontmostFinderWindowNumber {
            window.order(.above, relativeTo: finderWindowNumber)
        } else if !window.isVisible {
            // Accessibility fallback: without a Window Server ID there is no
            // safe relative target, but normal level still avoids floating
            // above unrelated windows.
            window.orderFront(nil)
        }
    }
}
