// swift-tools-version:5.9
import PackageDescription

// Builds the floating-panel host app directly with SwiftPM so the core
// experience works without full Xcode. The FinderSync extension target
// (toolbar button) still requires the generated FinderSidebar.xcodeproj.
let package = Package(
    name: "FinderSidebar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "FinderSidebarPanel",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "HostApp",
            exclude: ["Info.plist", "HostApp.entitlements"],
            // The hand-assembled bundle (build_app.sh) places Sparkle.framework
            // in Contents/Frameworks; the binary must look it up there.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "FinderSidebarPanelTests",
            dependencies: ["FinderSidebarPanel"],
            path: "SwiftTests"
        )
    ]
)
