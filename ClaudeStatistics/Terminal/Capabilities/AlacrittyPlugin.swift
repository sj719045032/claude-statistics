import ClaudeStatisticsKit
import Foundation

/// Stage-3 dogfood plugin. Wraps the existing
/// `AlacrittyTerminalCapability` in a `TerminalPlugin` shell so the
/// host's `PluginRegistry` exercises a real registration path while
/// the legacy `TerminalRegistry` keeps driving focus / launch.
///
/// Stage 4 splits this into a standalone `Plugins/Sources/AlacrittyPlugin/`
/// target packaged as `alacritty.csplugin`, with the capability's
/// behaviour folded into the plugin's own `makeFocusStrategy()` /
/// `makeLauncher()` factories. Until then the wrapper just exposes
/// the descriptor — the kernel still reaches the legacy capability
/// directly.
final class AlacrittyPlugin: TerminalPlugin {
    static let manifest = PluginManifest(
        id: "org.alacritty",
        kind: .terminal,
        displayName: "Alacritty",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.accessibility],
        principalClass: "AlacrittyPlugin"
    )

    private let capability = AlacrittyTerminalCapability()

    var descriptor: TerminalDescriptor { capability.descriptor }
    func detectInstalled() -> Bool { capability.isInstalled }
    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        TerminalFocusRouteRegistry.handler(for: capability.route)
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

    init() {}
}
