import Foundation

enum ProviderRegistry {
    static let selectedProviderDefaultsKey = "selectedProvider"
    static let defaultProvider: ProviderKind = .claude
    static let supportedProviders: [ProviderKind] = [.claude, .codex, .gemini]

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
        switch kind {
        case .claude:
            ClaudeProvider.shared
        case .codex:
            CodexProvider.shared
        case .gemini:
            GeminiProvider.shared
        }
    }
}
