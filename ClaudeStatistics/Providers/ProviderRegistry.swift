import Foundation

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
