import Foundation
import AppKit
import Combine

/// Polls Finder via AppleScript (osascript) for the front window's folder and
/// the current selection. This replaces the FinderSync extension for context:
/// it works from a plain SwiftPM-built app, at the cost of the user granting
/// an Apple Events ("automation") permission on first use.
final class FinderContext: ObservableObject {
    @Published private(set) var currentFolder: URL?
    @Published private(set) var selectedFiles: [URL] = []
    @Published private(set) var automationDenied = false

    private var timer: Timer?
    private let queue = DispatchQueue(label: "finder-context-poll")
    private var polling = false

    private static let script = """
    tell application "Finder"
        set output to ""
        try
            set output to POSIX path of (target of front Finder window as alias)
        end try
        try
            repeat with itemRef in (get selection)
                set output to output & linefeed & POSIX path of (itemRef as alias)
            end repeat
        end try
        return output
    end tell
    """

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        // Only bother Finder when it's frontmost; otherwise keep last context.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        guard !polling else { return }
        polling = true

        queue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.polling = false } }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", Self.script]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }

            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                // -1743: user declined the automation permission prompt.
                let denied = errText.contains("-1743")
                DispatchQueue.main.async { self?.automationDenied = denied }
                return
            }

            let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = outText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            let folder = lines.first.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL }
            let reportedSelection = lines.dropFirst()
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0).standardizedFileURL }
            // Finder's application-level `selection` can briefly belong to a
            // different window than `front Finder window`. Never combine that
            // stale selection with the front window's working directory.
            let selection = Self.selectionInFrontFolder(reportedSelection, folder: folder)

            DispatchQueue.main.async {
                self?.automationDenied = false
                self?.currentFolder = folder
                self?.selectedFiles = selection
            }
        }
    }

    nonisolated static func selectionInFrontFolder(_ selection: [URL], folder: URL?) -> [URL] {
        guard let folder = folder?.standardizedFileURL else { return [] }
        return selection.filter {
            $0.standardizedFileURL.deletingLastPathComponent() == folder
        }
    }
}
