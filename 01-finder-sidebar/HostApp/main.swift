import Cocoa

// Process entry point always runs on the main thread, so this isolation
// is safe even though top-level code in main.swift is nonisolated by default.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
