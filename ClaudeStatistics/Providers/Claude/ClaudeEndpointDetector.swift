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

}
