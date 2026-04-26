import ClaudeStatisticsKit
import Foundation

/// Stage-3 dogfood plugins for the remaining 7 builtin terminals.
/// Each one wraps the corresponding `TerminalCapability` so the host's
/// `PluginRegistry` exercises a real registration path while the
/// legacy `TerminalRegistry` keeps driving focus / launch.
///
/// Stage 4 splits each into a standalone `Plugins/Sources/<Name>Plugin/`
/// target packaged as `<id>.csplugin`, with the capability's
/// behaviour folded into the plugin's own factory methods. Until then
/// the wrappers expose only the descriptor + install detection — the
/// kernel still reaches the legacy capabilities directly.

final class ITermPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "com.googlecode.iterm2",
        kind: .terminal,
        displayName: "iTerm2",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.appleScript],
        principalClass: "ITermPlugin"
    )
    private let capability = ITermTerminalCapability()
    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    init() {}
}

final class AppleTerminalPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "com.apple.Terminal",
        kind: .terminal,
        displayName: "Terminal",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.appleScript],
        principalClass: "AppleTerminalPlugin"
    )
    private let capability = AppleTerminalCapability()
    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    init() {}
}

final class GhosttyPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "com.mitchellh.ghostty",
        kind: .terminal,
        displayName: "Ghostty",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.appleScript],
        principalClass: "GhosttyPlugin"
    )
    private let capability = GhosttyTerminalCapability()
    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    init() {}
}

final class KittyPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "net.kovidgoyal.kitty",
        kind: .terminal,
        displayName: "Kitty",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.filesystemHome],
        principalClass: "KittyPlugin"
    )
    private let capability = KittyTerminalCapability()
    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    init() {}
}

final class WezTermPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "com.github.wez.wezterm",
        kind: .terminal,
        displayName: "WezTerm",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "WezTermPlugin"
    )
    private let capability = WezTermTerminalCapability()
    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    init() {}
}

final class WarpPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "dev.warp.Warp-Stable",
        kind: .terminal,
        displayName: "Warp",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "WarpPlugin"
    )
    private let capability = WarpTerminalCapability()
    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    init() {}
}

final class EditorPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "com.tinystone.editor",
        kind: .terminal,
        displayName: "Editor",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "EditorPlugin"
    )
    private let capability = EditorTerminalCapability()
    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    init() {}
}
