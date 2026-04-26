import AppKit
import ClaudeStatisticsKit
import Foundation

/// Glue between the SDK's `TrustStore` and the host's UI: the loader's
/// `trustEvaluator` closure runs synchronously during plugin discovery
/// and cannot block on user input, so a fresh plugin's first encounter
/// is recorded as "pending" and **denied** for that boot. After
/// `AppState.init` finishes, the host calls `processPending(...)` to
/// prompt for each pending plugin and the user's decision applies on
/// the next launch.
///
/// Future direction (post-M2): swap the deferred reload for a hot path
/// that loads the plugin in-process the moment the user picks Allow.
/// Stable seam: replace `defaultPrompter` body and call
/// `PluginLoader.loadAll(...)` with a one-shot evaluator.
@MainActor
enum PluginTrustGate {
    /// Singleton trust store. Tests can swap it out via `setTrustStore`.
    private(set) static var trustStore = TrustStore()
    private static var pending: [PendingEntry] = []

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
    /// the user's decision to the trust store. Plugins the user
    /// allowed will be loaded on the next launch — first-version
    /// behaviour, see the type doc-comment for the hot-load follow-up.
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
        }
    }

    /// Reset state. Test-only.
    static func _resetForTesting(trustStore: TrustStore) {
        pending = []
        self.trustStore = trustStore
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
            Restart Claude Statistics for the decision to take effect.
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .allowed : .denied
    }
}
