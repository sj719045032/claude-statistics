import AppKit
import ClaudeStatisticsKit
import Foundation

/// Glue between the SDK's `TrustStore` / `DisabledPluginsStore` and
/// the host's UI. Two orthogonal concerns travel through this gate:
///
/// 1. **Trust** — `TrustStore` answers "is this on-disk binary safe
///    to load?" Hash-keyed so a swapped binary triggers a re-prompt.
///    `evaluate(...)` runs synchronously during plugin discovery and
///    can't block on user input, so a fresh plugin is recorded as
///    "pending" and **denied** for that boot. After `AppState.init`
///    finishes, the host calls `processPending(...)` to prompt for
///    each pending plugin.
///
/// 2. **Disable** — `DisabledPluginsStore` is the user-declared
///    kill switch, keyed by `manifest.id` only. Every source —
///    `.host`, `.bundled`, `.user` — consults it identically. A
///    disabled id never reaches the trust prompt; the loader stops
///    at the manifest stage and drops the manifest into
///    `registry.disabled` so the Settings panel can still show a
///    row with an Enable button.
///
/// Hot-load: when `pluginRegistry` is wired up via `setPluginRegistry`,
/// allowed plugins are dlopen'd + registered immediately and the
/// `onPluginHotLoaded` hook fires so host glue (terminal alias map,
/// provider lookup, focus resolver) can re-derive its caches without
/// a restart. Hot-enable for `.bundled` / `.user` follows the same
/// path; `.host` plugins need a restart because the host owns their
/// instantiation list.
@MainActor
enum PluginTrustGate {
    /// Singleton trust store. Tests can swap it out via `setTrustStore`.
    private(set) static var trustStore = TrustStore()
    /// Singleton disabled-set store. Tests swap via
    /// `_resetForTesting(disabledStore:)`.
    private(set) static var disabledStore = DisabledPluginsStore()
    private static var pending: [PendingEntry] = []
    private static weak var pluginRegistry: PluginRegistry?
    /// Host-plugin factory map injected by `AppState` after init.
    /// Lets `enable(...)` reinstantiate a compiled-in plugin so the
    /// re-enable becomes hot — without this, host plugins can only
    /// come back via app restart.
    private static var hostPluginFactories: [String: () -> any Plugin] = [:]
    /// Fired after a plugin is hot-loaded into `pluginRegistry`. The
    /// host wires this to its dynamic-registry refreshers so the new
    /// plugin's bundle ids / aliases / strategies become live without
    /// a restart.
    static var onPluginHotLoaded: ((PluginManifest, URL) -> Void)?

    /// Fired after a plugin is removed from `pluginRegistry` via
    /// `disable(...)`. Host re-derives dynamic registries so the
    /// disabled plugin's bundle ids / aliases / strategies stop
    /// resolving. The second argument is the plugin's provider
    /// descriptor id (e.g. "codex") for `.provider`/`.both` plugins
    /// — captured *before* unregister so the host can map manifest id
    /// → `ProviderKind` for store/VM teardown without re-querying the
    /// already-emptied registry. `nil` for non-provider plugins.
    static var onPluginDisabled: ((String, String?) -> Void)?

    static func setPluginRegistry(_ registry: PluginRegistry) {
        pluginRegistry = registry
    }

    /// AppState calls this once after init with the canonical map of
    /// host-plugin manifest ids → factories. The factories are simply
    /// the same `Plugin()` initializers used in the init list, but
    /// captured so a kill-switched then re-enabled host plugin can
    /// re-register without an app relaunch.
    static func setHostPluginFactories(_ factories: [String: () -> any Plugin]) {
        hostPluginFactories = factories
    }

    struct PendingEntry: Equatable {
        let manifest: PluginManifest
        let bundleURL: URL
    }

    static func setTrustStore(_ store: TrustStore) {
        trustStore = store
    }

    static func setDisabledStore(_ store: DisabledPluginsStore) {
        disabledStore = store
    }

    /// Read-through helper used by `AppState`'s host-plugin loop and
    /// the loader's per-bundle check.
    static func isDisabled(_ pluginId: String) -> Bool {
        disabledStore.isDisabled(pluginId)
    }

    /// Evaluator the loader calls per discovered plugin. `.allowed`
    /// → load, `.denied` or unknown → skip. Unknown plugins are
    /// queued so `processPending` can prompt for them after launch.
    /// Disabled plugins are skipped earlier inside the loader and
    /// never reach this evaluator.
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
    static func _resetForTesting(
        trustStore: TrustStore,
        disabledStore: DisabledPluginsStore = DisabledPluginsStore(
            storeURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("PluginTrustGateTests-disabled-\(UUID().uuidString).json")
        )
    ) {
        pending = []
        self.trustStore = trustStore
        self.disabledStore = disabledStore
    }

    /// Persist the user's "disable" decision. Sets the disabled-set
    /// flag (id-only, hash-independent) so every source is treated
    /// uniformly across restart, then unregisters the live plugin
    /// instance so the host stops handing it out for the rest of
    /// this session. The caller passes its own `PluginSource` snapshot
    /// (from `registry.source(for:)`) so the manifest can be parked
    /// under `registry.disabled` for the Settings UI to render an
    /// Enable row even after `unregister` wipes the source map.
    /// Returns whether the in-memory registry actually changed.
    ///
    /// Refuses to disable the last remaining provider plugin: the
    /// status bar entry depends on at least one being live, and a
    /// fully unconfigured app would have no UI surface to re-enable
    /// from. Caller (PluginsSettingsView) gates the Disable button
    /// on the same condition so this branch is just defence.
    @discardableResult
    static func disable(manifest: PluginManifest, source: PluginSource) -> Bool {
        if let registry = pluginRegistry,
           manifest.kind == .provider || manifest.kind == .both {
            let activeProviderCount = registry.providers.values
                .compactMap { $0 as? any ProviderPlugin }
                .count
            if activeProviderCount <= 1 {
                NSLog("[PluginTrustGate] Refusing to disable last provider %@", manifest.id)
                return false
            }
        }
        disabledStore.setDisabled(true, for: manifest.id)
        guard let registry = pluginRegistry else { return false }
        // Capture descriptor id before unregister wipes the bucket —
        // host uses it to find the matching `ProviderKind` for store
        // and VM teardown. Non-provider plugins yield nil.
        let providerDescriptorID = registry.providerPlugin(id: manifest.id)?.descriptor.id
        let removed = registry.unregister(id: manifest.id)
        // Always record the disabled snapshot — even if `unregister`
        // returned false (e.g. a `.both` plugin already pruned by an
        // earlier path), the UI still wants to see this id under
        // "Disabled" so the user can flip it back on.
        registry.recordDisabled(manifest: manifest, source: source)
        if removed {
            onPluginDisabled?(manifest.id, providerDescriptorID)
        }
        return removed
    }

    /// Reverse `disable(...)`: clear the kill-switch flag, drop any
    /// `.denied` trust record (leftover from the legacy code path
    /// that wrote both), then attempt a hot-reload for sources we
    /// can re-instantiate from disk. Returns the outcome so the
    /// Settings UI can render an appropriate hint.
    enum EnableOutcome {
        /// Plugin became live again without restart. Host glue was
        /// refreshed via `onPluginHotLoaded`.
        case hotLoaded
        /// Disabled flag is cleared but the plugin can only come
        /// back on next launch. Always the case for `.host` (no
        /// bundle to reload from).
        case restartRequired
        /// Reload from disk failed (e.g. bundled .csplugin removed
        /// from the .app while the host was running). The disabled
        /// flag is cleared but the plugin won't appear until either
        /// a restart succeeds or the file shows up again.
        case hotLoadFailed(PluginLoader.SkipReason)
    }

    @discardableResult
    static func enable(manifest: PluginManifest, source: PluginSource) -> EnableOutcome {
        disabledStore.setDisabled(false, for: manifest.id)
        // Drop any leftover `.denied` decision from earlier flows so
        // a future binary swap re-prompts cleanly.
        if let url = source.bundleURL {
            trustStore.removeEntry(for: manifest, bundleURL: url)
        }
        guard let registry = pluginRegistry else { return .restartRequired }

        // Re-enable runs every applicable register path because a
        // single `manifest.id` can carry two plugin instances at once
        // — e.g. extracted `CodexPlugin` (kind=.provider, .csplugin)
        // and bundled `CodexAppPlugin` (kind=.terminal) both claim
        // "com.openai.codex". `disable` unregisters both via a single
        // `unregister(id:)` call, so `enable` has to re-register
        // both. We try the host factory first (it has no URL), then
        // any on-disk bundle the disabled record pointed at, and
        // count it a success if either one re-registered.
        var anyLoaded = false
        var lastFailure: PluginLoader.SkipReason?

        if let factory = hostPluginFactories[manifest.id] {
            let freshPlugin = factory()
            do {
                try registry.register(freshPlugin, source: .host)
                anyLoaded = true
                let freshManifest = type(of: freshPlugin).manifest
                onPluginHotLoaded?(freshManifest, URL(fileURLWithPath: "/"))
            } catch PluginRegistryError.duplicateId {
                // Already registered (e.g. a previous enable on a
                // dual-identity id already filled this bucket). Not
                // a failure.
            } catch {
                lastFailure = .bundleLoadFailed
            }
        }

        if let url = source.bundleURL {
            switch PluginLoader.loadOne(
                at: url,
                into: registry,
                trustEvaluator: { _, _ in true },
                source: source
            ) {
            case .success(let loadedManifest):
                anyLoaded = true
                onPluginHotLoaded?(loadedManifest, url)
            case .failure(.duplicateId):
                // Same as above — host factory may have already
                // filled this id, or we may have hot-loaded the
                // bundle once before. Either way, not a failure.
                break
            case .failure(let reason):
                lastFailure = reason
            }
        }

        if anyLoaded {
            registry.removeDisabledRecord(id: manifest.id)
            return .hotLoaded
        }
        if let lastFailure {
            return .hotLoadFailed(lastFailure)
        }
        // No host factory, no bundle URL — caller is asking to
        // enable a record we can't recreate without restart (e.g. a
        // .user plugin whose source URL got lost).
        return .restartRequired
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
