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

@objc(ITermPlugin)
final class ITermPlugin: NSObject, TerminalPlugin {
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
        AppleScriptTerminalFocusRouteHandler()
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        capability as? any TerminalReadinessProviding
    }
    func makeSetupWizard() -> (any TerminalSetupProviding)? {
        capability as? any TerminalSetupProviding
    }
    override init() { super.init() }
}

@objc(GhosttyPlugin)
final class GhosttyPlugin: NSObject, TerminalPlugin {
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
        AppleScriptTerminalFocusRouteHandler()
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        capability as? any TerminalReadinessProviding
    }
    func makeSetupWizard() -> (any TerminalSetupProviding)? {
        capability as? any TerminalSetupProviding
    }
    override init() { super.init() }
}

@objc(WezTermPlugin)
final class WezTermPlugin: NSObject, TerminalPlugin {
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
        CLITerminalFocusRouteHandler(kind: .wezterm)
    }
    func makeLauncher() -> (any TerminalLauncher)? {
        capability as? any TerminalLauncher
    }
    func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        capability as? any TerminalReadinessProviding
    }
    func makeSetupWizard() -> (any TerminalSetupProviding)? {
        capability as? any TerminalSetupProviding
    }
    override init() { super.init() }
}

