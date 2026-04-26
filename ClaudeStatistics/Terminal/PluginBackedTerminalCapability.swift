import AppKit
import Foundation
import ClaudeStatisticsKit

/// Bridges a `TerminalPlugin` (SDK-side) into the host's
/// `TerminalCapability` protocol so it can sit in the same
/// `TerminalRegistry.launchOptions` / `readinessOptions` lists as the
/// hardcoded builtins. Without this adapter, the picker only ever sees
/// `appCapabilities`, even though the user has installed `.csplugin`
/// bundles like `VSCodePlugin` / `ZedPlugin` and PluginRegistry has
/// their `descriptor`s.
///
/// The adapter forwards installation / launch / setup to whichever
/// optional sub-capability the plugin actually implements
/// (`makeLauncher`, `makeReadinessProvider`, `makeSetupWizard`). When
/// the plugin doesn't implement an aspect, the adapter falls back to
/// the protocol's default behaviour (e.g. `installationStatus()`
/// derives from `plugin.detectInstalled()`).
///
/// Not `@MainActor` so the conformance to non-isolated SDK protocols
/// (`TerminalLauncher`, `TerminalReadinessProviding`,
/// `TerminalSetupProviding`) doesn't cross actor boundaries; all the
/// SDK methods we forward to are themselves nonisolated.
final class PluginBackedTerminalCapability: NSObject, TerminalCapability {
    let plugin: any TerminalPlugin
    let manifestId: String
    private let descriptor: TerminalDescriptor
    let lazyLauncher: (any TerminalLauncher)?
    let lazyReadinessProvider: (any TerminalReadinessProviding)?
    let lazySetupProvider: (any TerminalSetupProviding)?

    init(plugin: any TerminalPlugin, manifestId: String) {
        self.plugin = plugin
        self.manifestId = manifestId
        self.descriptor = plugin.descriptor
        self.lazyLauncher = plugin.makeLauncher()
        self.lazyReadinessProvider = plugin.makeReadinessProvider()
        self.lazySetupProvider = plugin.makeSetupWizard()
        super.init()
    }

    // The descriptor's `id` doubles as the picker option id. Builtin
    // terminals already use the same convention (their `optionID`
    // equals `descriptor.id`), so this keeps user preferences keyed
    // off a stable identifier across the migration.
    var optionID: String? { descriptor.id }
    var category: TerminalCapabilityCategory { descriptor.category }
    var displayName: String { descriptor.displayName }
    var bundleIdentifiers: Set<String> { descriptor.bundleIdentifiers }
    var terminalNameAliases: Set<String> { descriptor.terminalNameAliases }
    var processNameHints: Set<String> { descriptor.processNameHints }
    var route: TerminalFocusRoute {
        // Pure-plugin terminals don't currently express their own
        // route; default to .accessibility so process-tree-walker
        // logic still treats them as focus targets.
        .accessibility
    }
    var isInstalled: Bool { plugin.detectInstalled() }
    var tabFocusPrecision: TerminalTabFocusPrecision { descriptor.focusPrecision }
    var autoLaunchPriority: Int? { descriptor.autoLaunchPriority }
    var boundProviderID: String? { descriptor.boundProviderID }
}

extension PluginBackedTerminalCapability: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        guard let lazyLauncher else {
            DiagnosticLogger.shared.warning(
                "PluginBackedTerminalCapability(\(manifestId)): no launcher; ignoring launch request"
            )
            return
        }
        lazyLauncher.launch(request)
    }
}

extension PluginBackedTerminalCapability: TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus {
        if let lazyReadinessProvider {
            return lazyReadinessProvider.installationStatus()
        }
        return isInstalled ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        if let lazyReadinessProvider {
            return lazyReadinessProvider.setupRequirements()
        }
        return isInstalled ? [] : [.appInstalled]
    }

    func setupActions() -> [TerminalSetupAction] {
        lazyReadinessProvider?.setupActions() ?? []
    }
}

extension PluginBackedTerminalCapability: TerminalSetupProviding {
    var setupTitle: String { lazySetupProvider?.setupTitle ?? displayName }
    var setupActionTitle: String { lazySetupProvider?.setupActionTitle ?? displayName }
    var setupConfigURL: URL? { lazySetupProvider?.setupConfigURL }

    func setupStatus() -> TerminalSetupStatus {
        if let lazySetupProvider {
            return lazySetupProvider.setupStatus()
        }
        // No plugin-supplied setup wizard: report ready so the host
        // doesn't render an empty Setup button. Plugins that actually
        // need user-driven configuration override `makeSetupWizard()`
        // to surface their own status / wizard.
        return TerminalSetupStatus(isReady: true, isAvailable: true, summary: "", detail: nil)
    }

    func ensureSetup() throws -> TerminalSetupResult {
        if let lazySetupProvider {
            return try lazySetupProvider.ensureSetup()
        }
        return TerminalSetupResult(changed: false, message: "", backupURL: nil)
    }
}
