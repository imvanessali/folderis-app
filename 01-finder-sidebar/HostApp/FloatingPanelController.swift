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

/// The collapsed state: the panel shrinks to a narrow full-height rail flush
/// against the Finder window's right edge — just the brand icon and a ">"
/// chevron; clicking anywhere on it re-opens the full panel.
private struct CollapsedRailView: View {
    let onTap: () -> Void

    /// Rail width when the panel is collapsed.
    static let width: CGFloat = 56
    /// Visible icon diameter.
    private static let iconSize: CGFloat = 32

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                iconFace
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 与展开态面板同一套底色/圆角/描边：读起来是“同一块面板变窄”。
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .help(L("展开 Folderis", "Expand Folderis"))
    }

    /// 品牌 logo（发布包内 OrbLogo.png）；开发构建无资源时退回符号样式。
    private var iconFace: some View {
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
        .frame(width: Self.iconSize, height: Self.iconSize)
        .clipShape(Circle())
    }

    private var fallbackIcon: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 14))
            .foregroundStyle(Color.accentColor)
    }
}

@MainActor
final class FloatingPanelController: NSObject {
    private let panel: NSPanel
    private let railPanel: NSPanel
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

        // The collapsed rail: a narrow full-height borderless panel that sits
        // exactly where the full panel does, so collapsing reads as the panel
        // itself getting narrower.
        railPanel = SidebarPanel(
            contentRect: NSRect(x: 0, y: 0, width: CollapsedRailView.width, height: 600),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        railPanel.isFloatingPanel = true
        railPanel.level = .normal
        railPanel.hidesOnDeactivate = false
        railPanel.isOpaque = false
        railPanel.backgroundColor = .clear
        railPanel.hasShadow = true
        railPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init()

        railPanel.contentView = NSHostingView(
            rootView: CollapsedRailView(onTap: { [weak self] in self?.expand() })
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
        railPanel.orderOut(nil)
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
            railPanel.orderOut(nil)
            return
        }

        // 安装镜像（只读卷）的访达窗口不贴面板：安装页不需要 AI 助手。
        if let folder = finderContext.currentFolder,
           let ro = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly,
           ro {
            panel.orderOut(nil)
            railPanel.orderOut(nil)
            return
        }

        // Collapsed → the narrow rail takes the panel's place, same docking
        // rules; expanded → the full panel. Only one of the two is on screen.
        let active = isCollapsed ? railPanel : panel
        let inactive = isCollapsed ? panel : railPanel
        let width = isCollapsed ? CollapsedRailView.width : Self.panelWidth
        inactive.orderOut(nil)

        // Finder is active but we can't get its window frame. If that's
        // because Accessibility isn't granted yet, park at the screen's right
        // edge so the permission guidance stays visible; if it's simply that
        // no Finder window is open (desktop click), hide.
        guard let finderFrame else {
            // 只有“确实有 Finder 窗口在屏，但因未授权拿不到位置”时才停靠：
            // 点桌面这类没有窗口的激活不该把面板弹出来。
            guard !tracker.accessibilityGranted, tracker.finderHasOnScreenWindow() else {
                active.orderOut(nil)
                return
            }
            if let visible = NSScreen.main?.visibleFrame {
                let parked = NSRect(
                    x: visible.maxX - width,
                    y: visible.minY,
                    width: width,
                    height: visible.height
                )
                active.setFrame(parked, display: true)
            }
            orderDirectlyAboveFinder(active)
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
        let overflow = (finder.maxX + gap + width) - visible.maxX
        if overflow > 2 {
            let newWidth = max(Self.minFinderWidth, finder.width - overflow)
            var newX = finder.minX
            if finder.minX + newWidth + gap + width > visible.maxX {
                // Shrinking alone isn't enough (window too far right / too
                // narrow already): also slide the window left.
                newX = max(visible.minX, visible.maxX - width - gap - newWidth)
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
            width: width,
            height: finder.height
        )
        active.setFrame(panelFrame, display: true)
        orderDirectlyAboveFinder(active)
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
