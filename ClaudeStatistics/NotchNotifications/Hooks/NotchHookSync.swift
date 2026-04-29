import Foundation
import ClaudeStatisticsKit

/// Cross-provider hook installer dispatcher. Walks every available
/// provider, fetches its `notchHookInstaller` (when one exists), and
/// installs / uninstalls based on the per-provider master switch.
///
/// Pulled out of the per-provider hook installer files when Codex
/// extracted to a `.csplugin` — this enum is host-side glue (touches
/// `ProviderRegistry` + `NotchPreferences`, neither of which plugins
/// see) and doesn't belong inside any single plugin's bundle.
enum NotchHookSync {
    /// Collected from each provider's own declaration — no central
    /// list to keep in sync. A provider without a `notchHookInstaller`
    /// simply sits out. `plugins` filters out provider plugins the
    /// user has disabled so their hook installers don't keep mounting
    /// on every notch reconciliation.
    @MainActor
    static func installers(plugins: PluginRegistry?) -> [any HookInstalling] {
        ProviderRegistry.availableProviders(plugins: plugins).compactMap { kind in
            ProviderRegistry.provider(for: kind).notchHookInstaller
        }
    }

    /// Install or uninstall each provider's hooks based on its own
    /// master switch.
    @MainActor
    @discardableResult
    static func syncCurrent(plugins: PluginRegistry? = nil) async throws -> HookInstallResult {
        var sawConfirmationDenied = false

        for installer in installers(plugins: plugins) {
            // Builtin installers always have a kind that maps back to
            // the legacy enum; default to .claude for the impossible
            // no-match path so the loop stays total.
            let kind = ProviderKind(rawValue: installer.providerId) ?? .claude
            let enabled = NotchPreferences.isEnabled(kind)
            let result = enabled
                ? try await installer.install()
                : try await installer.uninstall()

            switch result {
            case .success:
                continue
            case .confirmationDenied:
                sawConfirmationDenied = true
            case .failure(let error):
                throw error
            }
        }

        if sawConfirmationDenied { return .confirmationDenied }
        return .success
    }
}
