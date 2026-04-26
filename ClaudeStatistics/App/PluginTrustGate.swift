import AppKit
import ClaudeStatisticsKit
import Foundation

/// Glue between the SDK's `TrustStore` and the host's UI: the loader's
/// `trustEvaluator` closure runs synchronously during plugin discovery
/// and cannot block on user input, so a fresh plugin's first encounter
/// is recorded as "pending" and **denied** for that boot. After
/// `AppState.init` finishes, the host calls `processPending(...)` to
/// prompt for each pending plugin.
///
/// Hot-load: when `pluginRegistry` is wired up via `setPluginRegistry`,
/// allowed plugins are dlopen'd + registered immediately and the
/// `onPluginHotLoaded` hook fires so host glue (terminal alias map,
/// provider lookup, focus resolver) can re-derive its caches without
/// a restart. If the registry isn't wired (tests / first launch
/// edge), the user has to relaunch — same behaviour as before.
@MainActor
enum PluginTrustGate {
    /// Singleton trust store. Tests can swap it out via `setTrustStore`.
    private(set) static var trustStore = TrustStore()
    private static var pending: [PendingEntry] = []
    private static weak var pluginRegistry: PluginRegistry?
    /// Fired after a plugin is hot-loaded into `pluginRegistry`. The
    /// host wires this to its dynamic-registry refreshers so the new
    /// plugin's bundle ids / aliases / strategies become live without
    /// a restart.
    static var onPluginHotLoaded: ((PluginManifest, URL) -> Void)?

    /// Fired after a plugin is removed from `pluginRegistry` via
    /// `disable(...)`. Host re-derives dynamic registries so the
    /// disabled plugin's bundle ids / aliases / strategies stop
    /// resolving.
    static var onPluginDisabled: ((String) -> Void)?

    static func setPluginRegistry(_ registry: PluginRegistry) {
        pluginRegistry = registry
    }

    struct PendingEntry: Equatable {
        let manifest: PluginManifest
        let bundleURL: URL
    }

    static func setTrustStore(_ store: TrustStore) {
        trustStore = store
    }

    /// Evaluator the loader calls per discovered plugin. `.allowed`
    /// → load, `.denied` or unknown → skip. Unknown plugins are
    /// queued so `processPending` can prompt for them after launch.
    static func evaluate(manifest: PluginManifest, bundleURL: URL) -> Bool {
        switch trustStore.decision(for: manifest, bundleURL: bundleURL) {
        case .allowed:
            return true
        case .denied:
            return false
        case .none:
            let entry = PendingEntry(manifest: manifest, bundleURL: bundleURL)
            if !pending.contains(entry) {
                pending.append(entry)
            }
            return false
        }
    }

    static func snapshotPending() -> [PendingEntry] {
        pending
    }

    /// Drain the pending queue, prompt for each plugin, and persist
    /// the user's decision to the trust store. Allowed plugins are
    /// hot-loaded into `pluginRegistry` immediately when it's wired;
    /// `onPluginHotLoaded` fires per success so host glue refreshes.
    static func processPending(
        prompter: (PendingEntry) -> TrustStore.Decision = defaultPrompter
    ) {
        let queue = pending
        pending = []
        for entry in queue {
            let decision = prompter(entry)
            trustStore.record(
                decision,
                for: entry.manifest,
                bundleURL: entry.bundleURL
            )
            guard decision == .allowed,
                  let registry = pluginRegistry else { continue }
            switch PluginLoader.loadOne(at: entry.bundleURL, into: registry) {
            case .success(let manifest):
                onPluginHotLoaded?(manifest, entry.bundleURL)
            case .failure(let reason):
                NSLog(
                    "[PluginTrustGate] hot-load failed for %@: %@",
                    entry.bundleURL.lastPathComponent,
                    String(describing: reason)
                )
            }
        }
    }

    /// Reset state. Test-only.
    static func _resetForTesting(trustStore: TrustStore) {
        pending = []
        self.trustStore = trustStore
    }

    /// Revoke a previously-allowed plugin: persist `.denied`,
    /// unregister from `pluginRegistry`, and fire
    /// `onPluginDisabled` so host glue re-derives. Returns whether
    /// anything actually changed.
    @discardableResult
    static func disable(manifest: PluginManifest, bundleURL: URL) -> Bool {
        trustStore.record(.denied, for: manifest, bundleURL: bundleURL)
        guard let registry = pluginRegistry else { return false }
        let removed = registry.unregister(id: manifest.id)
        if removed {
            onPluginDisabled?(manifest.id)
        }
        return removed
    }

    static let defaultPrompter: (PendingEntry) -> TrustStore.Decision = { entry in
        let alert = NSAlert()
        alert.messageText = "Allow plugin: \(entry.manifest.displayName)?"
        let permissions = entry.manifest.permissions.isEmpty
            ? "(none declared)"
            : entry.manifest.permissions.map(\.rawValue).joined(separator: ", ")
        alert.informativeText = """
            Identifier: \(entry.manifest.id)
            Version: \(entry.manifest.version)
            Source: \(entry.bundleURL.path)
            Declared permissions: \(permissions)

            Plugins are not signed-checked. Only allow plugins you trust.
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .allowed : .denied
    }
}
