import ClaudeStatisticsKit
import Foundation

/// Reverses a marketplace install: yank the plugin out of
/// `PluginRegistry`, flip its trust to denied, delete the bundle on
/// disk, then erase the trust record entirely so a future reinstall
/// behaves like a fresh one.
///
/// macOS can't truly unload a `dlopen`'d Mach-O — the principal class
/// stays in memory until the host quits. That's fine: the registry is
/// the source of truth for every lookup (`provider(for:)` /
/// `pluginStrategyResolver` / etc.), so dropping the row from there
/// neutralises the plugin's contribution. Deleting the file plus the
/// trust entry just makes the next launch behave as if the plugin had
/// never been installed.
@MainActor
enum PluginUninstaller {
    enum UninstallError: Error {
        /// The plugin lives in a source we don't allow uninstalling
        /// (host-resident, or bundled inside the .app — the user
        /// would have to delete the .app to remove those).
        case sourceNotUserInstalled
        case fileRemovalFailed(String)
    }

    /// `trustStore` defaults to `PluginTrustGate.trustStore` (resolved
    /// at call-time, not at parameter-default-evaluation, since that
    /// runs in a non-isolated context). The `.denied` write that
    /// `disable(...)` performs and the `removeEntry(...)` call below
    /// must land on **the same** json file — passing a different
    /// `TrustStore` instance would split the writes and corrupt
    /// state. The test suite injects via
    /// `PluginTrustGate._resetForTesting` to keep the singleton in
    /// sync.
    @discardableResult
    static func uninstall(
        manifest: PluginManifest,
        source: PluginSource,
        registry: PluginRegistry,
        trustStore: TrustStore? = nil
    ) throws -> URL {
        let resolvedTrustStore = trustStore ?? PluginTrustGate.trustStore
        // 1. Sanity-gate: only `.user(...)` is allowed. host plugins
        //    come back next launch, bundled plugins ship with the
        //    .app — uninstalling either is a no-op the user
        //    wouldn't expect.
        guard case .user(let bundleURL) = source else {
            throw UninstallError.sourceNotUserInstalled
        }

        // 2. Disable: drop from registry, set the kill-switch flag,
        //    fire onPluginDisabled so host glue refreshes terminal
        //    aliases / provider lookup. PluginTrustGate has the
        //    canonical implementation we already exercise from the
        //    Settings → Disable button.
        PluginTrustGate.disable(manifest: manifest, source: source)

        // 3. Delete the bundle.
        do {
            try FileManager.default.removeItem(at: bundleURL)
        } catch {
            throw UninstallError.fileRemovalFailed(String(describing: error))
        }

        // 4. Clean up state so a reinstall starts fresh:
        //    - Remove the trust entry so the next install isn't
        //      shadowed by a stale prior decision (we never write
        //      `.denied` here anymore, but legacy installs might).
        //    - Clear the kill-switch flag so the reinstalled plugin
        //      isn't immediately filtered out by the disabled set.
        //    - Drop the parked "disabled" snapshot from the registry
        //      so the Settings panel doesn't keep ghosting the row.
        resolvedTrustStore.removeEntry(for: manifest, bundleURL: bundleURL)
        PluginTrustGate.disabledStore.setDisabled(false, for: manifest.id)
        registry.removeDisabledRecord(id: manifest.id)

        return bundleURL
    }
}
