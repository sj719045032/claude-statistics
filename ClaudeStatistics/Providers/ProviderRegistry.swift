import Foundation

enum ProviderRegistry {
    static let selectedProviderDefaultsKey = "selectedProvider"
    static let defaultProvider: ProviderKind = .claude
    static let supportedProviders: [ProviderKind] = [.claude, .codex]

    static func selectedProviderKind() -> ProviderKind {
        guard let raw = UserDefaults.standard.string(forKey: selectedProviderDefaultsKey),
              let kind = ProviderKind(rawValue: raw) else {
            return defaultProvider
        }
        return kind
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
        }
    }
}
