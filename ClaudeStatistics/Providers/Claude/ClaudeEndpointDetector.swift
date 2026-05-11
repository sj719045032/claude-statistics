import Foundation
import ClaudeStatisticsKit

/// Endpoint detector for the Claude provider. Phase C makes this
/// `IdentityStore`-aware: instead of always returning whatever the
/// user has in `~/.claude/settings.json`, it consults the global
/// identity selection first.
///
/// - When the active identity is `.anthropicOAuth`, return `.empty`
///   so the subscription router skips and the host falls through to
///   the OAuth profile path.
/// - When the active identity is `.subscription(adapterID, _)`, ask
///   the matching `SubscriptionAccountManager` for its
///   `activeEndpoint` — that's where the live token + base URL come
///   from (synced from CLI in MVP, app-keychain in Phase C-6).
///
/// `detectFromCLISettings()` exposes the raw CLI parse for managers
/// that synthesize "synced-from-CLI" identities (currently only GLM).
struct ClaudeEndpointDetector: EndpointDetector {
    func detect() -> EndpointInfo {
        switch IdentityStore.shared.activeIdentity {
        case .anthropicOAuth:
            return .empty
        case .subscription(let adapterID, _):
            guard let manager = SubscriptionAdapterRouter.shared
                .accountManager(adapterID: adapterID) else {
                return .empty
            }
            return manager.activeEndpoint ?? .empty
        }
    }

    /// Raw Claude CLI settings, ignoring the app's selected identity.
    /// Used by integrations that run *inside* Claude Code (status line)
    /// and therefore must follow the CLI's current endpoint/token, not
    /// whichever account the app is currently inspecting.
    static func detectFromCLISettings() -> EndpointInfo {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let parsed = try? JSONDecoder().decode(EnvelopeShape.self, from: data) else {
            return .empty
        }
        let env = parsed.env ?? [:]
        let baseURLString = env["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let apiKey = (env["ANTHROPIC_AUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return EndpointInfo(baseURL: baseURL, apiKey: (apiKey?.isEmpty ?? true) ? nil : apiKey)
    }

    private struct EnvelopeShape: Decodable {
        let env: [String: String]?
    }
}
