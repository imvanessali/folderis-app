// swift-tools-version:5.9
import PackageDescription

// Builds the floating-panel host app directly with SwiftPM so the core
// experience works without full Xcode. The FinderSync extension target
// (toolbar button) still requires the generated FinderSidebar.xcodeproj.
let package = Package(
    name: "FinderSidebar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FinderSidebarPanel",
            path: "HostApp",
            exclude: ["Info.plist", "HostApp.entitlements"]
        ),
        .testTarget(
            name: "FinderSidebarPanelTests",
            dependencies: ["FinderSidebarPanel"],
            path: "SwiftTests"
        )
    ]
)
