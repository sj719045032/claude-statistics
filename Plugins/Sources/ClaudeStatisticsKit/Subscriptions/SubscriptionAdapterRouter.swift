import Foundation
import Combine

/// Global registry of `SubscriptionAdapter`s. Builtin adapters and
/// plugin-contributed adapters both reach the registry through the
/// same `register(_:)` entry point — host calls it for `.host`-source
/// plugins at startup, and again for each plugin's
/// `makeSubscriptionAdapters()` after the loader finishes.
///
/// Routing rule: pick the first adapter whose `providerID` matches
/// AND whose `matchingHosts` contains the active base URL's host.
/// Fallback: if no host match, pick one whose `matchingHosts`
/// contains the literal `"default"` — that's the official endpoint
/// adapter (Anthropic OAuth, etc.).
@MainActor
public final class SubscriptionAdapterRouter: ObservableObject {
    public static let shared = SubscriptionAdapterRouter()

    private var adapters: [any SubscriptionAdapter] = []
    private var detectors: [String: any EndpointDetector] = [:]
    /// `adapterID -> manager`. Populated during `refresh(from:)` so
    /// the host's identity picker can list every adapter's accounts
    /// without needing to know which adapter shipped which manager.
    @Published public private(set) var accountManagers: [String: SubscriptionAccountManager] = [:]
    /// `adapterID -> adapter`. Lets host code look up an adapter by
    /// the same id its manager was constructed with — used when
    /// `IdentityStore` has explicitly selected a subscription account
    /// and the host should bypass `matchingHosts` (the user's chosen
    /// base URL might be a custom proxy outside the adapter's
    /// declared host list).
    private var adaptersByAdapterID: [String: any SubscriptionAdapter] = [:]

    private init() {}

    public func register(_ adapter: any SubscriptionAdapter) {
        adapters.append(adapter)
    }

    public func registerDetector(_ detector: any EndpointDetector, forProviderID providerID: String) {
        detectors[providerID] = detector
    }

    /// Drop every adapter / detector associated with a given provider
    /// id. Used when a plugin is disabled so the router doesn't keep
    /// handing out adapters belonging to a now-disabled plugin.
    public func unregisterAll(providerID: String) {
        adapters.removeAll { $0.providerID == providerID }
        detectors.removeValue(forKey: providerID)
    }

    public func adapter(forProviderID providerID: String, baseURL: URL?) -> (any SubscriptionAdapter)? {
        let candidates = adapters.filter { $0.providerID == providerID }
        if let host = baseURL?.host {
            if let exact = candidates.first(where: { $0.matchingHosts.contains(host) }) {
                return exact
            }
            return candidates.first(where: { $0.matchingHosts.contains("default") })
        }
        return candidates.first(where: { $0.matchingHosts.contains("default") })
    }

    public func adapters(forProviderID providerID: String) -> [any SubscriptionAdapter] {
        adapters.filter { $0.providerID == providerID }
    }

    public func detector(forProviderID providerID: String) -> (any EndpointDetector)? {
        detectors[providerID]
    }

    /// Wipe and rebuild the router from a plugin registry — call this
    /// once at startup after `PluginRegistry` is populated, and again
    /// after any enable/disable hot-load so the router reflects the
    /// current set of provider plugins. Each plugin contributes its
    /// adapters via `makeSubscriptionAdapters()` and its endpoint
    /// detector via `makeEndpointDetector()`.
    public func refresh(from registry: PluginRegistry) {
        adapters.removeAll()
        detectors.removeAll()
        accountManagers.removeAll()
        adaptersByAdapterID.removeAll()

        // Provider plugins contribute their own endpoint detector
        // (Claude reads ~/.claude/settings.json) and may bring
        // builtin SubscriptionAdapters too.
        for plugin in registry.providers.values {
            guard let providerPlugin = plugin as? any ProviderPlugin else { continue }
            let providerID = providerPlugin.descriptor.id
            for adapter in providerPlugin.makeSubscriptionAdapters() {
                registerAdapter(adapter)
            }
            if let detector = providerPlugin.makeEndpointDetector() {
                detectors[providerID] = detector
            }
        }

        // Subscription-extension plugins (GLM, OpenRouter, …) live
        // alongside provider plugins and contribute their adapters
        // without bringing a CLI of their own. The router doesn't
        // care which kind a plugin is — adapters from both go into
        // the same `adapters` array, paired by `(providerID, host)`.
        for plugin in registry.subscriptionExtensions.values {
            guard let extPlugin = plugin as? any SubscriptionExtensionPlugin else { continue }
            for adapter in extPlugin.makeSubscriptionAdapters() {
                registerAdapter(adapter)
            }
        }

        DiagnosticLogger.shared.info(
            "SubscriptionRouter.refresh: adapters=\(adapters.count) detectors=\(detectors.count) managers=\(accountManagers.count)"
        )
    }

    private func registerAdapter(_ adapter: any SubscriptionAdapter) {
        adapters.append(adapter)
        if let manager = adapter.makeAccountManager() {
            accountManagers[manager.adapterID] = manager
            adaptersByAdapterID[manager.adapterID] = adapter
        }
    }

    /// Look up an adapter by the id its manager was constructed
    /// with. Used by the host when `IdentityStore` has picked a
    /// specific subscription account — routing skips `matchingHosts`
    /// so user-supplied custom URLs work end-to-end.
    public func adapter(forAdapterID adapterID: String) -> (any SubscriptionAdapter)? {
        adaptersByAdapterID[adapterID]
    }

    /// Look up the manager belonging to a given adapter id (the
    /// `adapterID` the manager was constructed with). Returns nil
    /// if no adapter has registered a manager under that id.
    public func accountManager(adapterID: String) -> SubscriptionAccountManager? {
        accountManagers[adapterID]
    }

    /// Snapshot of every registered manager, sorted for stable UI
    /// ordering. Used by the identity picker to render rows.
    public func allAccountManagers() -> [SubscriptionAccountManager] {
        accountManagers.values.sorted { $0.adapterID < $1.adapterID }
    }
}

/// Classify the active credential setup for a provider given its
/// detector output and the registered adapters. Used by the Settings
/// UI to swap the green-✓/red-✗ block with a meaningful chip.
@MainActor
public enum CredentialClassifier {
    public static func classify(
        providerID: String,
        endpoint: EndpointInfo,
        oauthTokenPresent: Bool
    ) -> CredentialKind {
        if let host = endpoint.baseURL?.host {
            if SubscriptionAdapterRouter.shared
                .adapter(forProviderID: providerID, baseURL: endpoint.baseURL) != nil,
               !host.hasSuffix("anthropic.com") {
                return .thirdParty(host: host)
            }
            if !host.hasSuffix("anthropic.com"), endpoint.apiKey != nil {
                return .thirdParty(host: host)
            }
        }
        if oauthTokenPresent { return .oauth }
        if endpoint.apiKey != nil { return .apiKey }
        return .missing
    }
}
