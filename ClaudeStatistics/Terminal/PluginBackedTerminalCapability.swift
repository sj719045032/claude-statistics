import AppKit
import Foundation
@preconcurrency import ClaudeStatisticsKit

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
    private let installationCache = PluginInstallationCache()

    init(plugin: any TerminalPlugin, manifestId: String) {
        self.plugin = plugin
        self.manifestId = manifestId
        self.descriptor = plugin.descriptor
        self.lazyLauncher = plugin.makeLauncher()
        self.lazyReadinessProvider = plugin.makeReadinessProvider()
        self.lazySetupProvider = plugin.makeSetupWizard()
        super.init()
        installationCache.seed(from: descriptor)
        refreshInstallationCache()
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
    var isInstalled: Bool {
        refreshInstallationCache()
        return installationCache.snapshot.status == .installed
    }
    var tabFocusPrecision: TerminalTabFocusPrecision { descriptor.focusPrecision }
    var autoLaunchPriority: Int? { descriptor.autoLaunchPriority }
    var boundProviderID: String? { descriptor.boundProviderID }

    private func refreshInstallationCache() {
        installationCache.refreshIfNeeded(manifestId: manifestId) { [plugin, lazyReadinessProvider] in
            if let lazyReadinessProvider {
                let status = lazyReadinessProvider.installationStatus()
                return PluginInstallationSnapshot(
                    status: status,
                    requirements: lazyReadinessProvider.setupRequirements()
                )
            }

            let isInstalled = plugin.detectInstalled()
            return PluginInstallationSnapshot(
                status: isInstalled ? .installed : .notInstalled,
                requirements: isInstalled ? [] : [.appInstalled]
            )
        }
    }
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
        refreshInstallationCache()
        return installationCache.snapshot.status
    }

    func setupRequirements() -> [TerminalRequirement] {
        refreshInstallationCache()
        return installationCache.snapshot.requirements
    }

    func setupActions() -> [TerminalSetupAction] {
        lazyReadinessProvider?.setupActions() ?? []
    }
}

private struct PluginInstallationSnapshot {
    let status: TerminalInstallationStatus
    let requirements: [TerminalRequirement]
}

private final class PluginInstallationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached = PluginInstallationSnapshot(status: .notInstalled, requirements: [.appInstalled])
    private var refreshInFlight = false
    private var hasRefreshed = false

    var snapshot: PluginInstallationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func seed(from descriptor: TerminalDescriptor) {
        let appInstalled = descriptor.bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        lock.lock()
        cached = PluginInstallationSnapshot(
            status: appInstalled ? .installed : .notInstalled,
            requirements: appInstalled ? [] : [.appInstalled]
        )
        lock.unlock()
    }

    func refreshIfNeeded(
        manifestId: String,
        resolve: @escaping @Sendable () -> PluginInstallationSnapshot
    ) {
        lock.lock()
        if refreshInFlight || hasRefreshed {
            lock.unlock()
            return
        }
        refreshInFlight = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = resolve()
            guard let self else { return }
            lock.lock()
            cached = resolved
            hasRefreshed = true
            refreshInFlight = false
            lock.unlock()
            DiagnosticLogger.shared.verbose("PluginBackedTerminalCapability(\(manifestId)): refreshed installation cache status=\(resolved.status)")
        }
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
