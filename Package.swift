// swift-tools-version:5.9
import PackageDescription

// SwiftPM exposure of ClaudeStatisticsKit — the SDK third-party
// `.csplugin` projects (and the catalog repo's first-party plugins)
// import to conform to `Plugin` / `ProviderPlugin` / `TerminalPlugin`
// / etc. The host app itself still builds via xcodegen + the
// `.xcodeproj` (where ClaudeStatisticsKit is registered as a regular
// Framework target); this Package.swift is purely the doorway for
// out-of-repo consumers.
//
// Adding a new SDK source file? Drop it into
// `Plugins/Sources/ClaudeStatisticsKit/` — both xcodegen and SwiftPM
// pick it up automatically (xcodegen via the target's `sources` glob,
// SwiftPM via the explicit `path` below). No registration in either
// Package.swift or project.yml needed for individual files.
let package = Package(
    name: "ClaudeStatisticsKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClaudeStatisticsKit",
            targets: ["ClaudeStatisticsKit"]
        )
    ],
    targets: [
        .target(
            name: "ClaudeStatisticsKit",
            path: "Plugins/Sources/ClaudeStatisticsKit"
        )
    ]
)
