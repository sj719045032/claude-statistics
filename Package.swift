// swift-tools-version:5.9
import PackageDescription

// SwiftPM exposure of ClaudeStatisticsKit as a binary framework.
// Catalog-repo plugins (and third-party `.csplugin` projects) link
// this prebuilt `.xcframework` so plugin runtime carries the SAME
// protocol metadata as the host's
// `Contents/Frameworks/ClaudeStatisticsKit.framework` — Swift
// runtime conformance checks (`cls as? (NSObject & Plugin).Type`)
// resolve correctly across the load boundary.
//
// Why binary, not source: a source-based `.target(path:)` form
// static-linked the entire SDK (76 files / 2389 symbols) into every
// plugin binary, producing a duplicate `Plugin` protocol descriptor
// inside each plugin. The Swift runtime then refused the principal
// class cast at load time (`principalClassWrongType`). Binary
// distribution via xcframework is the standard fix and the same
// pattern Apple-platform SDK vendors (Sentry, Firebase, Mixpanel,
// etc.) ship with.
//
// Releasing a new SDK build:
//   1. `bash scripts/build-xcframework.sh` produces
//      `build/xcframework/ClaudeStatisticsKit.xcframework.zip` and
//      prints the SwiftPM checksum.
//   2. Bump the URL tag below (`sdk-v<major.minor.patch>`) and
//      replace the checksum.
//   3. Create the matching GitHub release on
//      `sj719045032/claude-statistics` with the zip uploaded as an
//      asset.
//   4. Commit the Package.swift change + push.
//
// The host app itself still builds via xcodegen + the `.xcodeproj`
// (where ClaudeStatisticsKit is registered as a regular Framework
// target from source); this Package.swift is purely the doorway for
// out-of-repo SwiftPM consumers.
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
        // SDK_MODE_BEGIN — managed by scripts/sdk-mode.sh
        .binaryTarget(
            name: "ClaudeStatisticsKit",
            path: "build/xcframework/ClaudeStatisticsKit.xcframework"
        )
        // SDK_MODE_END
    ]
)
