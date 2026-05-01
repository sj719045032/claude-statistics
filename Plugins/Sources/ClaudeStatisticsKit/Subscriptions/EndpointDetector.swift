import Foundation

/// Per-provider hook that turns "what's in the user's CLI settings"
/// into the (baseURL, apiKey) tuple the subscription router needs.
/// Each provider knows its own settings file layout (Claude reads
/// `~/.claude/settings.json` `env`, Codex reads `~/.codex/config.toml`,
/// Gemini reads its own GCP-style config). Centralising this as a
/// protocol keeps `SubscriptionAdapterRouter` provider-agnostic.
@MainActor
public protocol EndpointDetector: Sendable {
    func detect() -> EndpointInfo
}

public struct EndpointInfo: Sendable, Equatable {
    public let baseURL: URL?
    public let apiKey: String?

    public init(baseURL: URL?, apiKey: String?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public static let empty = EndpointInfo(baseURL: nil, apiKey: nil)
}

/// Classification of how a provider is currently authenticated.
/// Drives the Settings UI: OAuth shows a tier badge, API-key shows
/// a "API Key" chip, third-party shows the host name, missing shows
/// the existing red ✗. Replaces the old `Bool?` "has token" check
/// which couldn't tell a third-party CLI user apart from a logged-out
/// one and so flagged real users as "credentials not found".
public enum CredentialKind: Sendable, Equatable {
    case oauth
    case apiKey
    case thirdParty(host: String)
    case missing
}
