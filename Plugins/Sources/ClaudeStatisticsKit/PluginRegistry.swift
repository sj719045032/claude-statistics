import Foundation

/// Central runtime registry of all loaded plugins. Replaces the
/// closed-enum `ProviderRegistry` and the static `TerminalRegistry`
/// array — new plugins (Provider / Terminal / ShareRole /
/// ShareCardTheme) register themselves at startup, and the kernel
/// iterates the registry instead of `switch`-ing on a fixed enum.
///
/// Stage-3 introduces this type and its public API; stage 4 migrates
/// the kernel's existing `ProviderRegistry` and `TerminalRegistry`
/// look-ups to read from here. Until then the registry is constructed
/// but unused — the kernel keeps its current code paths.
/// How a plugin reached the registry. Lets the Settings panel
/// (and diagnostics) tell host-resident plugins apart from on-disk
/// `.csplugin` bundles, and bundled samples apart from user
/// installs.
public enum PluginSource: Sendable, Equatable {
    /// Class compiled into the host binary — e.g. the dogfood
    /// wrappers for the 3 provider + 8 builtin terminal adapters.
    case host
    /// `.csplugin` shipped inside the host's `Contents/PlugIns`
    /// directory; implicitly trusted.
    case bundled(url: URL)
    /// `.csplugin` discovered under
    /// `~/Library/Application Support/Claude Statistics/Plugins`;
    /// gated by `TrustStore`.
    case user(url: URL)

    public var bundleURL: URL? {
        switch self {
        case .host: return nil
        case .bundled(let url), .user(let url): return url
        }
    }
}

/// Snapshot of a plugin the host knows about but didn't register
/// because it's currently disabled. Carries the manifest so the
/// Settings UI can render a row even though no live `Plugin`
/// instance exists in the registry.
public struct DisabledRecord: Sendable {
    public let manifest: PluginManifest
    public let source: PluginSource

    public init(manifest: PluginManifest, source: PluginSource) {
        self.manifest = manifest
        self.source = source
    }
}

@MainActor
public final class PluginRegistry {
    public init() {}

    /// Per-kind storage. Public read-only views are exposed as plain
    /// dictionaries so callers can iterate or look up by id without
    /// learning the registry's mutation API.
    public private(set) var providers:   [String: any Plugin] = [:]
    public private(set) var terminals:   [String: any Plugin] = [:]
    public private(set) var shareRoles:  [String: any Plugin] = [:]
    public private(set) var shareThemes: [String: any Plugin] = [:]
    /// Subscription-extension plugins (GLM, OpenRouter, …) keyed by
    /// `manifest.id`. They piggy-back on an existing provider's CLI
    /// and contribute `SubscriptionAdapter`s through the
    /// `SubscriptionExtensionPlugin` protocol.
    public private(set) var subscriptionExtensions: [String: any Plugin] = [:]

    /// Per-id record of how each plugin reached the registry. Source
    /// information is keyed by `manifest.id` — `.both` plugins land
    /// in two buckets but share one source entry.
    public private(set) var sources: [String: PluginSource] = [:]

    /// Plugins the host saw at startup but skipped because the user
    /// disabled them. The Settings panel reads this so disabled
    /// plugins still appear in the list (with an Enable button)
    /// instead of vanishing. Keyed by `manifest.id` so the UI can
    /// dedupe across sources.
    public private(set) var disabled: [String: DisabledRecord] = [:]

    /// Register a freshly-instantiated plugin. The registry stores it
    /// against `manifest.id` in the bucket(s) implied by `manifest.kind`.
    /// Re-registration with the same id throws — duplicate ids signal
    /// either a config mistake or a clash between two plugins claiming
    /// the same vendor namespace.
    ///
    /// `source` defaults to `.host` since most callers (the dogfood
    /// wrappers in `AppState`) compile the plugin directly. The loader
    /// passes `.bundled(...)` or `.user(...)` so the Settings panel
    /// can show the on-disk origin.
    public func register(_ plugin: any Plugin, source: PluginSource = .host) throws {
        let manifest = type(of: plugin).manifest
        switch manifest.kind {
        case .provider:
            try insert(plugin, into: &providers, id: manifest.id, bucket: "provider")
        case .terminal:
            try insert(plugin, into: &terminals, id: manifest.id, bucket: "terminal")
        case .shareRole:
            try insert(plugin, into: &shareRoles, id: manifest.id, bucket: "shareRole")
        case .shareCardTheme:
            try insert(plugin, into: &shareThemes, id: manifest.id, bucket: "shareCardTheme")
        case .both:
            try insert(plugin, into: &providers, id: manifest.id, bucket: "provider")
            try insert(plugin, into: &terminals, id: manifest.id, bucket: "terminal")
        case .subscriptionExtension:
            try insert(plugin, into: &subscriptionExtensions, id: manifest.id, bucket: "subscriptionExtension")
        }
        sources[manifest.id] = source
    }

    public func source(for pluginID: String) -> PluginSource? {
        sources[pluginID]
    }

    /// Stash a manifest the host saw on disk (or in the dogfood list)
    /// but skipped because the user has disabled the plugin. Removes
    /// the same id from the registered buckets if it was somehow
    /// already there, so disabled and registered states stay
    /// mutually exclusive.
    public func recordDisabled(manifest: PluginManifest, source: PluginSource) {
        unregister(id: manifest.id)
        disabled[manifest.id] = DisabledRecord(manifest: manifest, source: source)
    }

    /// Drop a previously-recorded disabled snapshot. Called when the
    /// user clicks Enable, after the host re-registers (or restarts
    /// to re-register) the plugin.
    @discardableResult
    public func removeDisabledRecord(id: String) -> Bool {
        disabled.removeValue(forKey: id) != nil
    }

    /// Snapshot of every plugin the registry knows is disabled. Used
    /// by the Settings panel to populate the "Disabled" section.
    public func disabledRecords() -> [DisabledRecord] {
        Array(disabled.values)
    }

    /// Remove a plugin from every bucket it occupies plus the source
    /// map. Used by the Settings panel's Disable button so a user can
    /// revoke a previously-allowed `.csplugin` without restarting the
    /// host. macOS doesn't truly unload a Mach-O bundle once it's
    /// dlopen'd, so the principal class stays in memory — this just
    /// makes the registry stop handing it out, which is enough to
    /// neutralise the plugin's contribution (focus / launch /
    /// readiness lookups all consult the registry).
    @discardableResult
    public func unregister(id: String) -> Bool {
        let inProviders = providers.removeValue(forKey: id) != nil
        let inTerminals = terminals.removeValue(forKey: id) != nil
        let inShareRoles = shareRoles.removeValue(forKey: id) != nil
        let inShareThemes = shareThemes.removeValue(forKey: id) != nil
        let inSubExt = subscriptionExtensions.removeValue(forKey: id) != nil
        let removed = inProviders || inTerminals || inShareRoles || inShareThemes || inSubExt
        if removed {
            sources.removeValue(forKey: id)
        }
        return removed
    }

    // MARK: - Typed look-ups

    /// Returns the registered Provider plugin for the given id, or
    /// `nil` if no plugin claims it.
    public func providerPlugin(id: String) -> (any ProviderPlugin)? {
        providers[id] as? any ProviderPlugin
    }

    /// Returns the registered Terminal plugin for the given id, or
    /// `nil` if no plugin claims it.
    public func terminalPlugin(id: String) -> (any TerminalPlugin)? {
        terminals[id] as? any TerminalPlugin
    }

    /// Returns the registered Share-role plugin for the given id, or
    /// `nil` if no plugin claims it.
    public func shareRolePlugin(id: String) -> (any ShareRolePlugin)? {
        shareRoles[id] as? any ShareRolePlugin
    }

    /// Returns the registered Share-card-theme plugin for the given
    /// id, or `nil` if no plugin claims it.
    public func shareThemePlugin(id: String) -> (any ShareCardThemePlugin)? {
        shareThemes[id] as? any ShareCardThemePlugin
    }

    /// Snapshot of every loaded plugin's manifest. Useful for the
    /// Settings → Plugins panel and the load-report log.
    public func loadedManifests() -> [PluginManifest] {
        let all: [any Plugin] = Array(providers.values)
            + Array(terminals.values)
            + Array(shareRoles.values)
            + Array(shareThemes.values)
            + Array(subscriptionExtensions.values)
        // Dedup by id (a `.both` plugin shows up twice across buckets).
        var seen: Set<String> = []
        return all.compactMap { plugin in
            let manifest = type(of: plugin).manifest
            guard seen.insert(manifest.id).inserted else { return nil }
            return manifest
        }
    }

    private func insert(
        _ plugin: any Plugin,
        into bucket: inout [String: any Plugin],
        id: String,
        bucket bucketName: String
    ) throws {
        if bucket[id] != nil {
            throw PluginRegistryError.duplicateId(id: id, bucket: bucketName)
        }
        bucket[id] = plugin
    }
}

public enum PluginRegistryError: Error, CustomStringConvertible {
    case duplicateId(id: String, bucket: String)

    public var description: String {
        switch self {
        case .duplicateId(let id, let bucket):
            return "Plugin id '\(id)' already registered in '\(bucket)' bucket"
        }
    }
}
