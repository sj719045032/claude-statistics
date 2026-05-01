import Foundation
import Combine

/// Process-wide selection of "which user identity is currently live
/// for the active provider". Drives every downstream data-source
/// decision: when active is `.anthropicOAuth`, host reads the OAuth
/// `.credentials.json` and shows tier badges; when active is
/// `.subscription(adapterID, accountID)`, host routes through that
/// adapter (GLM / OpenRouter / Kimi …) instead.
///
/// Persisted in `UserDefaults` so the choice survives restarts. The
/// store doesn't enforce that the chosen identity actually exists —
/// if e.g. the user removes a GLM token externally, host code reads
/// `EndpointDetector.detect()` getting `.empty`, the subscription
/// loader returns nil, and `ProfileViewModel` falls back to the
/// OAuth path. Self-healing.
@MainActor
public final class IdentityStore: ObservableObject {
    public static let shared = IdentityStore()

    public enum ActiveIdentity: Equatable, Codable, Sendable {
        /// The user's current Anthropic OAuth account (managed by
        /// `ClaudeAccountManager` in the host). Multiple OAuth
        /// accounts share this case; the OAuth manager owns its own
        /// "which one is selected" state.
        case anthropicOAuth
        /// A token-based account belonging to a specific subscription
        /// adapter. `adapterID` matches `SubscriptionAdapter` /
        /// `SubscriptionAccountManager.adapterID`; `accountID`
        /// matches a `SubscriptionAccount.id` inside that manager.
        case subscription(adapterID: String, accountID: String)
    }

    @Published public private(set) var activeIdentity: ActiveIdentity = .anthropicOAuth

    private let defaults: UserDefaults
    private static let storageKey = "IdentityStore.activeIdentity.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(ActiveIdentity.self, from: data) {
            self.activeIdentity = decoded
        }
    }

    public func activate(_ identity: ActiveIdentity) {
        guard activeIdentity != identity else { return }
        activeIdentity = identity
        if let data = try? JSONEncoder().encode(identity) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
