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

    @discardableResult
    static func uninstall(
        manifest: PluginManifest,
        source: PluginSource,
        registry: PluginRegistry,
        trustStore: TrustStore = TrustStore()
    ) throws -> URL {
        // 1. Sanity-gate: only `.user(...)` is allowed. host plugins
        //    come back next launch, bundled plugins ship with the
        //    .app — uninstalling either is a no-op the user
        //    wouldn't expect.
        guard case .user(let bundleURL) = source else {
            throw UninstallError.sourceNotUserInstalled
        }

        // 2. Disable: persist .denied, drop from registry, fire
        //    onPluginDisabled so host glue refreshes terminal
        //    aliases / provider lookup. PluginTrustGate has the
        //    canonical implementation we already exercise from the
        //    Settings → Disable button.
        PluginTrustGate.disable(manifest: manifest, bundleURL: bundleURL)

        // 3. Delete the bundle.
        do {
            try FileManager.default.removeItem(at: bundleURL)
        } catch {
            throw UninstallError.fileRemovalFailed(String(describing: error))
        }

        // 4. Remove the trust record so a reinstall isn't blocked
        //    by the .denied flag we just wrote in step 2. (Same
        //    plugin, fresh path — but path-equality isn't guaranteed
        //    after delete-and-recreate.) Keying off both manifest.id
        //    and Info.plist hash means even a re-prompt would only
        //    match the old record, but cleaning up here makes the
        //    intent explicit.
        trustStore.removeEntry(for: manifest, bundleURL: bundleURL)

        return bundleURL
    }
}
