import Foundation
import ClaudeStatisticsKit

enum ProviderRegistry {
    static let selectedProviderDefaultsKey = "selectedProvider"
    static let defaultProvider: ProviderKind = .claude
    static let supportedProviders: [ProviderKind] = [.claude, .codex, .gemini]

    /// Plugin-contributed `SessionProvider` instances keyed by
    /// `descriptor.id`. Populated by `AppState` after `pluginRegistry`
    /// finishes loading: each `ProviderPlugin.makeProvider()` result
    /// caches here so `provider(for:)` can prefer plugin-supplied
    /// instances before falling back to the legacy switch. Builtin
    /// dogfood wrappers return `*.shared` singletons so behaviour is
    /// equivalent; the seam exists so a third-party plugin (when bundle
    /// loading lands in M2) can swap a builtin out by registering with
    /// the same id.
    private static let dynamicProviders = ProviderInstanceStore()
    /// Pricing entries contributed by `ProviderPlugin`s whose descriptor
    /// id falls outside the builtin `ProviderKind` enum. Maintained as a
    /// snapshot so `ModelPricing.builtinModels()` can read it from any
    /// thread without main-actor isolation. Refreshed by `AppState`
    /// after every plugin hot-load / disable.
    private static let extraPricingStore = ExtraPricingStore()

    /// Weak handle to the live `PluginRegistry` so static helpers
    /// reachable from places without a registry-in-scope (e.g.
    /// `ModelPricing.builtinModels`) can still consult plugin state.
    /// Set once by `AppState` after init; nil before that, in which
    /// case helpers fall back to the hardcoded `supportedProviders`
    /// trio.
    @MainActor
    private static weak var sharedPluginRegistry: PluginRegistry?

    @MainActor
    static func setSharedPluginRegistry(_ registry: PluginRegistry?) {
        sharedPluginRegistry = registry
    }

    @MainActor
    static func currentSharedPluginRegistry() -> PluginRegistry? {
        sharedPluginRegistry
    }

    static func registerDynamicProvider(_ provider: any SessionProvider, for id: String) {
        dynamicProviders.add(provider, for: id)
    }

    /// Public lookup for callers that have a descriptor id (often
    /// plugin-contributed) but no `ProviderKind`. Used by aggregation
    /// helpers like `ModelPricing.builtinModels`.
    static func dynamicLookup(id: String) -> (any SessionProvider)? {
        dynamicProviders.lookup(id)
    }

    /// Snapshot of pricing rows contributed by plugin providers whose
    /// descriptor id has no matching `ProviderKind` (i.e. true
    /// third-party adapters, not the builtin trio). Thread-safe.
    static func extraPluginPricing() -> [String: ModelPricingRates] {
        extraPricingStore.snapshot()
    }

    /// Refresh the extra-pricing cache from the live `PluginRegistry`.
    /// Called by `AppState` after every plugin hot-load and disable.
    @MainActor
    static func refreshExtraPluginPricing(plugins: PluginRegistry?) {
        guard let plugins else {
            extraPricingStore.set([:])
            return
        }
        var merged: [String: ModelPricingRates] = [:]
        for plugin in plugins.providers.values {
            guard let providerPlugin = plugin as? any ProviderPlugin else { continue }
            let descriptorId = providerPlugin.descriptor.id
            // Skip the three builtins — those are already covered by
            // `provider(for: kind).builtinPricingModels` in the loop
            // ModelPricing.builtinModels does first.
            if ProviderKind(rawValue: descriptorId) != nil { continue }
            guard let provider = providerPlugin.makeProvider() else { continue }
            merged.merge(provider.builtinPricingModels) { current, _ in current }
        }
        extraPricingStore.set(merged)
    }

    static func unregisterDynamicProvider(id: String) {
        dynamicProviders.remove(id: id)
    }

    /// Drop every plugin-contributed instance. Called by AppState
    /// before re-wiring so a `disable` is reflected — without this,
    /// the dynamic store keeps the old `GeminiProvider.shared`
    /// pointer and `provider(for: .gemini)` keeps returning it even
    /// after the Gemini plugin is unregistered.
    static func clearDynamicProviders() {
        dynamicProviders.removeAll()
    }

    static func availableProviders() -> [ProviderKind] {
        supportedProviders.filter { provider(for: $0).isInstalled }
    }

    /// Plugin-aware variant: pulls every currently-enabled provider out
    /// of `allKnownDescriptors(plugins:)` (so disabled builtins drop
    /// out and third-party `ProviderPlugin` ids are included), then
    /// filters by each provider's own `isInstalled` check. Callers with
    /// a `PluginRegistry` in scope — every UI surface, the startup
    /// bootstrap, the notch reconciliation — should prefer this
    /// signature so a kill-switched provider really disappears from
    /// the host and a hot-loaded plugin one shows up automatically.
    @MainActor
    static func availableProviders(plugins: PluginRegistry?) -> [ProviderKind] {
        allKnownDescriptors(plugins: plugins).compactMap { descriptor -> ProviderKind? in
            guard let kind = ProviderKind(rawValue: descriptor.id) else { return nil }
            return provider(for: kind).isInstalled ? kind : nil
        }
    }

    /// Every provider descriptor known to the host **and currently
    /// enabled** in `pluginRegistry`. Used by UI surfaces (Settings
    /// menu-bar toggles, the menu-bar usage strip, notch reconciliation,
    /// the developer rebuild-index list) so adding a `ProviderPlugin`
    /// causes it to appear without touching the surface, and disabling
    /// one causes it to disappear in the same edit cycle.
    ///
    /// Builtin descriptors come first when present so existing users
    /// see the same order they're used to; plugin contributions append
    /// after, in the dictionary's iteration order. Pass `nil` to get
    /// the legacy builtin-only list — used by paths that run before
    /// `AppState` has wired the registry (initial pricing decode).
    @MainActor
    static func allKnownDescriptors(plugins: PluginRegistry? = nil) -> [ProviderDescriptor] {
        guard let plugins else {
            return supportedProviders.map(\.descriptor)
        }
        var seen: Set<String> = []
        var result: [ProviderDescriptor] = []
        // Builtin descriptors in canonical order, but only those whose
        // `ProviderPlugin` is still registered in PluginRegistry. A
        // disabled builtin (e.g. user kill-switched Gemini) drops out
        // here so every consumer of `allKnownDescriptors` — menu bar
        // strip, settings toggles, notch enable check — sees it gone.
        for kind in supportedProviders {
            let descriptorId = kind.descriptor.id
            let stillRegistered = plugins.providers.values.contains { plugin in
                (plugin as? any ProviderPlugin)?.descriptor.id == descriptorId
            }
            guard stillRegistered, seen.insert(descriptorId).inserted else { continue }
            result.append(kind.descriptor)
        }
        // Plugin-contributed descriptors with ids outside the builtin
        // set get appended after.
        for plugin in plugins.providers.values {
            guard let providerPlugin = plugin as? any ProviderPlugin else { continue }
            let descriptor = providerPlugin.descriptor
            if seen.insert(descriptor.id).inserted {
                result.append(descriptor)
            }
        }
        return result
    }

    static func preferredProviderKind() -> ProviderKind {
        let available = availableProviders()
        if available.contains(defaultProvider) {
            return defaultProvider
        }
        return available.first ?? defaultProvider
    }

    static func selectedProviderKind() -> ProviderKind {
        guard let raw = UserDefaults.standard.string(forKey: selectedProviderDefaultsKey),
              let kind = ProviderKind(rawValue: raw) else {
            let fallback = preferredProviderKind()
            persistSelectedProvider(fallback)
            return fallback
        }

        let available = availableProviders()
        if available.isEmpty || available.contains(kind) {
            return kind
        }

        let fallback = preferredProviderKind()
        persistSelectedProvider(fallback)
        return fallback
    }

    static func persistSelectedProvider(_ kind: ProviderKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: selectedProviderDefaultsKey)
    }

    static func provider(for kind: ProviderKind) -> any SessionProvider {
        if let dynamic = dynamicProviders.lookup(kind.rawValue) {
            return dynamic
        }
        switch kind {
        case .claude:
            return ClaudeProvider.shared
        default:
            // Unknown ProviderKind id reaching this fallback means a
            // plugin-registered provider missed the dynamic lookup
            // above. Returning the Claude shared instance preserves
            // the legacy "default to Claude" behaviour the rawValue
            // init? path used to give us.
            return ClaudeProvider.shared
        }
    }
}

private final class ExtraPricingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotData: [String: ModelPricingRates] = [:]

    func set(_ data: [String: ModelPricingRates]) {
        lock.lock()
        defer { lock.unlock() }
        snapshotData = data
    }

    func snapshot() -> [String: ModelPricingRates] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotData
    }
}

private final class ProviderInstanceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var instances: [String: any SessionProvider] = [:]

    func add(_ provider: any SessionProvider, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        instances[id] = provider
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        instances.removeValue(forKey: id)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        instances.removeAll()
    }

    func lookup(_ id: String) -> (any SessionProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return instances[id]
    }
}
