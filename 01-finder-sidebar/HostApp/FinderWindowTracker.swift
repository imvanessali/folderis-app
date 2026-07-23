import Cocoa
import ApplicationServices
import Combine

/// Uses the Accessibility API to find the frontmost Finder window's frame,
/// since FinderSync extensions cannot report window geometry themselves.
/// Requires the user to grant Accessibility permission to this app in
/// System Settings > Privacy & Security > Accessibility.
final class FinderWindowTracker: ObservableObject {
    @Published private(set) var frontmostFinderWindowFrame: CGRect?
    /// Window Server ID for the Finder window represented by
    /// `frontmostFinderWindowFrame`. The panel uses this to sit immediately
    /// above that Finder window instead of floating above every Finder window.
    @Published private(set) var frontmostFinderWindowNumber: Int?
    @Published private(set) var accessibilityGranted: Bool = AXIsProcessTrusted()
    /// True when Finder (or this app itself, e.g. while typing in the panel)
    /// is the active application — the panel only shows in that case.
    @Published private(set) var isFinderFrontmost = false

    private var timer: Timer?
    private var axObserver: AXObserver?
    private var observedPID: pid_t?

    func start() {
        requestPermissionIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        teardownObserver()
    }

    /// Event-driven tracking: window-moved/resized notifications keep firing
    /// throughout a drag, whereas synchronous AX polling can starve while the
    /// target app sits in its drag event loop.
    private func setupObserverIfNeeded(for pid: pid_t) {
        guard observedPID != pid else { return }
        teardownObserver()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FinderWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.schedulePoll()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Only low-frequency window-level events. Element-level notifications
        // (created/destroyed) are a firehose in Finder and will saturate the
        // main thread with polls.
        for note in [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXFocusedWindowChangedNotification
        ] {
            AXObserverAddNotification(observer, appElement, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        observedPID = pid
    }

    /// Coalesces bursts of AX notifications into at most one poll per
    /// run-loop pass.
    private var pollScheduled = false

    private func schedulePoll() {
        guard !pollScheduled else { return }
        pollScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.pollScheduled = false
            self?.poll()
        }
    }

    private func teardownObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        observedPID = nil
    }

    private func requestPermissionIfNeeded() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func activeAppChanged() {
        poll()
    }

    private func poll() {
        accessibilityGranted = AXIsProcessTrusted()

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // 本 App 自己在前台（例如正在面板里打字）只延续既有的跟踪状态；
        // 若此前没在跟随任何 Finder 窗口，激活本 App 不应让面板凭空出现。
        let selfIsFront = front == Bundle.main.bundleIdentifier
        isFinderFrontmost = front == "com.apple.finder"
            || (selfIsFront && frontmostFinderWindowFrame != nil)

        guard accessibilityGranted, isFinderFrontmost else {
            frontmostFinderWindowNumber = nil
            frontmostFinderWindowFrame = nil
            return
        }
        guard let finderPID = findFinderPID() else {
            frontmostFinderWindowNumber = nil
            frontmostFinderWindowFrame = nil
            return
        }
        setupObserverIfNeeded(for: finderPID)

        let appElement = AXUIElementCreateApplication(finderPID)
        // Never let a busy Finder (mid-drag) hang our reads: fail fast and
        // retry on the next tick/notification instead of queueing for 6s.
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        // Collect Finder's standard windows (excludes Quick Look overlays,
        // sheets, the desktop) with their frames via Accessibility.
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AXUIElement] else {
            // Transient read failure (e.g. timeout mid-drag): keep the last
            // known frame instead of hiding the panel.
            return
        }
        let standardWindows: [(element: AXUIElement, frame: CGRect)] = axWindows.compactMap { window in
            guard Self.isStandardWindow(window), let frame = frame(of: window) else { return nil }
            return (window, frame)
        }
        guard !standardWindows.isEmpty else {
            frontmostFinderWindowNumber = nil
            frontmostFinderWindowFrame = nil
            return
        }

        // Z-order comes from the CG window list — unlike the AX focused
        // window it stays authoritative while the user drags the window.
        // The frontmost CG entry that matches a standard AX window wins.
        if let primary = NSScreen.screens.first,
           let cgList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in cgList {
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == finderPID,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
                let cocoaFrame = CGRect(
                    x: cgBounds.minX,
                    y: primary.frame.maxY - cgBounds.maxY,
                    width: cgBounds.width,
                    height: cgBounds.height
                )
                if let match = standardWindows.first(where: { Self.roughlyEqual($0.frame, cocoaFrame) }) {
                    frontWindowElement = match.element
                    frontmostFinderWindowNumber = info[kCGWindowNumber as String] as? Int
                    frontmostFinderWindowFrame = match.frame
                    return
                }
            }
            // 在屏窗口列表有效但没有任何匹配：AX 报的“标准窗口”都是
            // 最小化的或在其他空间——当前空间其实没有可见 Finder 窗口，
            // 不能让面板贴着一个看不见的窗口出现。
            frontWindowElement = nil
            frontmostFinderWindowNumber = nil
            frontmostFinderWindowFrame = nil
            return
        }

        // CG 列表拿不到时才退回 AX：focused standard window, else the first standard one.
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focusedValue {
            // swiftlint:disable:next force_cast
            let focused = focusedValue as! AXUIElement
            if Self.isStandardWindow(focused), let frame = frame(of: focused) {
                frontWindowElement = focused
                frontmostFinderWindowNumber = nil
                frontmostFinderWindowFrame = frame
                return
            }
        }
        frontWindowElement = standardWindows[0].element
        frontmostFinderWindowNumber = nil
        frontmostFinderWindowFrame = standardWindows[0].frame
    }

    private static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 &&
        abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    private static func isStandardWindow(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
              let subrole = subroleValue as? String else { return false }
        return subrole == kAXStandardWindowSubrole as String
    }

    private var frontWindowElement: AXUIElement?

    /// Resizes/moves the front Finder window (AppKit bottom-left coordinates).
    /// Used by the panel to "squeeze" Finder and claim screen space beside it.
    func setFrontFinderWindowFrame(_ rect: CGRect) {
        guard let element = frontWindowElement,
              let primary = NSScreen.screens.first else { return }

        var position = CGPoint(x: rect.minX, y: primary.frame.maxY - rect.maxY)
        var size = CGSize(width: rect.width, height: rect.height)

        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        // Reflect the change immediately so the panel doesn't wait a poll cycle.
        frontmostFinderWindowFrame = rect
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        // Accessibility uses a global top-left origin anchored to the primary
        // screen; AppKit uses bottom-left anchored to the same primary screen.
        // The conversion must therefore always use the primary screen's height,
        // not whichever screen the window happens to be on.
        guard let primary = NSScreen.screens.first else { return nil }

        let flippedY = primary.frame.maxY - (point.y + size.height)
        return CGRect(x: point.x, y: flippedY, width: size.width, height: size.height)
    }

    /// 不依赖辅助功能权限的粗判：当前空间是否有可见的 Finder 窗口。
    /// 供未授权时决定要不要停靠面板（避免点一下桌面面板就弹出来）。
    func finderHasOnScreenWindow() -> Bool {
        guard let pid = findFinderPID(),
              let cgList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return cgList.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    private func findFinderPID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.finder" }?
            .processIdentifier
    }
}
