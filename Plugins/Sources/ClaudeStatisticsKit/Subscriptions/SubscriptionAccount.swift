import Foundation

/// One subscription identity surfaced by a `SubscriptionAccountManager` —
/// equivalent to "one Anthropic OAuth login" but for token-based plans
/// (GLM, OpenRouter, Kimi …). The host's identity picker renders one
/// row per account; switching activates that account as the live
/// data source.
public struct SubscriptionAccount: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let label: String
    public let detailLine: String?
    /// Whether the host's identity picker should offer a "Remove"
    /// affordance for this account. The plugin sets this to `false`
    /// for read-only entries (e.g. synced-from-CLI identities the
    /// user manages externally) and `true` for app-managed entries.
    public let isRemovable: Bool

    public init(id: String, label: String, detailLine: String? = nil, isRemovable: Bool = true) {
        self.id = id
        self.label = label
        self.detailLine = detailLine
        self.isRemovable = isRemovable
    }
}
