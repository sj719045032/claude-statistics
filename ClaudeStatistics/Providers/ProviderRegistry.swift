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

    static func registerDynamicProvider(_ provider: any SessionProvider, for id: String) {
        dynamicProviders.add(provider, for: id)
    }

    static func availableProviders() -> [ProviderKind] {
        supportedProviders.filter { provider(for: $0).isInstalled }
    }

    /// Every provider descriptor known to the host: the three builtin
    /// kinds in their canonical order, then any third-party
    /// `ProviderPlugin` instance loaded into `pluginRegistry` that
    /// contributes an id outside the builtin set. Used by UI surfaces
    /// (Settings menu-bar toggles, the menu-bar usage strip, the
    /// developer rebuild-index list) so adding a `ProviderPlugin`
    /// causes it to appear without touching the surface.
    ///
    /// Builtin descriptors come first so existing users see the same
    /// order they're used to; plugin contributions append in the
    /// dictionary's iteration order (stable per launch but not across
    /// launches). Pass `nil` to get the legacy builtin-only list — used
    /// by paths that don't have a `PluginRegistry` in scope yet.
    @MainActor
    static func allKnownDescriptors(plugins: PluginRegistry? = nil) -> [ProviderDescriptor] {
        var seen: Set<String> = []
        var result: [ProviderDescriptor] = []
        for kind in supportedProviders {
            let descriptor = kind.descriptor
            if seen.insert(descriptor.id).inserted {
                result.append(descriptor)
            }
        }
        guard let plugins else { return result }
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
        case .codex:
            return CodexProvider.shared
        case .gemini:
            return GeminiProvider.shared
        }
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

    func lookup(_ id: String) -> (any SessionProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return instances[id]
    }
}
