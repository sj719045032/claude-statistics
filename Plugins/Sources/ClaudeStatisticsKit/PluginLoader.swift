import Foundation

/// Discovers and loads `.csplugin` bundles into a `PluginRegistry`.
///
/// The loader walks a directory of plugin bundles, reads each one's
/// `Info.plist` to recover its `PluginManifest`, asks the host whether
/// it trusts the plugin (Q2: signing not required, decision is the
/// host's), and on approval `dlopen`s the bundle and instantiates the
/// `principalClass` via the Objective-C runtime.
///
/// Builtin plugins skip this path — they're registered directly during
/// app launch. The loader exists for the M2 third-party path: drop a
/// `Plugins/Sources/<Name>Plugin/` build product into the per-user
/// plugins directory and the host picks it up on next launch.
@MainActor
public enum PluginLoader {
    /// Default per-user plugin directory:
    /// `~/Library/Application Support/Claude Statistics/Plugins/`. Host
    /// callers may pass a different URL (e.g. `Contents/PlugIns/` for
    /// builtin samples shipped inside the app).
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support
            .appendingPathComponent("Claude Statistics", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    public struct Report: Sendable {
        public let loaded: [PluginManifest]
        public let skipped: [SkippedEntry]

        public init(loaded: [PluginManifest], skipped: [SkippedEntry]) {
            self.loaded = loaded
            self.skipped = skipped
        }
    }

    public struct SkippedEntry: Sendable {
        public let url: URL
        public let reason: SkipReason

        public init(url: URL, reason: SkipReason) {
            self.url = url
            self.reason = reason
        }
    }

    public enum SkipReason: Sendable, Equatable, Error {
        case notACSplugin
        case manifestMissing
        case incompatibleAPIVersion(required: SemVer, host: SemVer)
        case trustDenied
        case disabled
        case bundleLoadFailed
        case principalClassMissing(name: String)
        case principalClassWrongType(name: String)
        case duplicateId(id: String, bucket: String)
    }

    /// Trust callback. Returns `true` to load the plugin, `false` to
    /// skip. Host wires this to its `TrustStore` + first-run prompt.
    /// Default `{ _, _ in true }` is intentional — the loader is a
    /// mechanism, the policy lives in the host.
    public typealias TrustEvaluator =
        @MainActor (_ manifest: PluginManifest, _ bundleURL: URL) -> Bool

    /// Disabled-flag callback. Returns `true` if the user has
    /// explicitly disabled this plugin id. When true, the loader
    /// stops at the manifest stage (no `dlopen`), records the
    /// manifest as disabled in the registry so the Settings panel
    /// can still display a row, and returns `.failure(.disabled)`.
    /// Default `{ _ in false }` keeps callers that don't care
    /// (tests, hot-load) on the legacy path.
    public typealias DisabledChecker =
        @MainActor (_ pluginId: String) -> Bool

    /// `sourceKind` controls how the registry tags each loaded plugin:
    /// pass `.bundled` when scanning `Contents/PlugIns/` and `.user`
    /// (default) when scanning the per-user plugin directory.
    public enum SourceKind: Sendable {
        case bundled
        case user
    }

    @discardableResult
    public static func loadAll(
        from directory: URL,
        into registry: PluginRegistry,
        trustEvaluator: TrustEvaluator = { _, _ in true },
        disabledChecker: DisabledChecker = { _ in false },
        sourceKind: SourceKind = .user
    ) -> Report {
        var loaded: [PluginManifest] = []
        var skipped: [SkippedEntry] = []

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return Report(loaded: [], skipped: [])
        }

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let source: PluginSource = sourceKind == .bundled ? .bundled(url: url) : .user(url: url)
            switch loadOne(
                at: url,
                into: registry,
                trustEvaluator: trustEvaluator,
                disabledChecker: disabledChecker,
                source: source
            ) {
            case .success(let manifest):
                loaded.append(manifest)
            case .failure(let reason):
                // `notACSplugin` for non-bundle entries is just noise
                // when iterating a directory shared with other content
                // (PlugIns/ holds .xctest at build time, etc.). Drop
                // it here so callers don't get a SkippedEntry per
                // unrelated file.
                if case .notACSplugin = reason { continue }
                skipped.append(SkippedEntry(url: url, reason: reason))
            }
        }

        return Report(loaded: loaded, skipped: skipped)
    }

    /// Load a single `.csplugin` bundle. Used by `loadAll` while
    /// walking a directory and by the host's hot-load path
    /// (`PluginTrustGate.processPending` calling here once the user
    /// picks Allow). The trust evaluator can be a no-op `{ _, _ in true }`
    /// in the hot-load case because the user just answered the prompt
    /// — `TrustStore` is updated separately.
    ///
    /// `source` is forwarded to `PluginRegistry.register` so the
    /// Settings panel can show whether a plugin shipped inside the
    /// `.app` (`.bundled`) or was installed by the user
    /// (`.user`). When the caller doesn't care, the default is
    /// `.user(url: url)` — most external callers are user-install
    /// paths.
    @discardableResult
    public static func loadOne(
        at url: URL,
        into registry: PluginRegistry,
        trustEvaluator: TrustEvaluator = { _, _ in true },
        disabledChecker: DisabledChecker = { _ in false },
        source: PluginSource? = nil
    ) -> Result<PluginManifest, SkipReason> {
        guard url.pathExtension == "csplugin" else {
            return .failure(.notACSplugin)
        }
        guard let bundle = Bundle(url: url),
              let manifest = PluginManifest(bundle: bundle) else {
            return .failure(.manifestMissing)
        }
        guard manifest.minHostAPIVersion <= SDKInfo.apiVersion else {
            return .failure(.incompatibleAPIVersion(
                required: manifest.minHostAPIVersion,
                host: SDKInfo.apiVersion
            ))
        }
        // Disabled check runs before trust: a disabled plugin
        // shouldn't trigger a trust prompt either, and the user
        // already saw it once when they originally enabled it.
        if disabledChecker(manifest.id) {
            registry.recordDisabled(
                manifest: manifest,
                source: source ?? .user(url: url)
            )
            return .failure(.disabled)
        }
        guard trustEvaluator(manifest, url) else {
            return .failure(.trustDenied)
        }
        guard bundle.load() else {
            return .failure(.bundleLoadFailed)
        }
        guard let cls = bundle.classNamed(manifest.principalClass) else {
            return .failure(.principalClassMissing(name: manifest.principalClass))
        }
        guard let pluginType = cls as? (NSObject & Plugin).Type else {
            return .failure(.principalClassWrongType(name: manifest.principalClass))
        }
        let plugin = pluginType.init()
        do {
            try registry.register(plugin, source: source ?? .user(url: url))
            return .success(manifest)
        } catch let PluginRegistryError.duplicateId(id, bucket) {
            return .failure(.duplicateId(id: id, bucket: bucket))
        } catch {
            // PluginRegistry currently only throws duplicateId; future
            // error cases land here and are reported as a generic
            // bundleLoadFailed so the loader stays resilient.
            return .failure(.bundleLoadFailed)
        }
    }
}
