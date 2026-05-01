import Foundation

/// Snapshot returned by a `SubscriptionAdapter`. Carries everything
/// the UI needs to render the Settings → Account card, the menu-bar
/// percentage, and the optional "open dashboard" affordance — all
/// keyed by canonical units so a Claude tier badge and a GLM token
/// quota share the same rendering paths.
public struct SubscriptionInfo: Sendable, Codable, Equatable {
    public let planName: String
    public let quotas: [SubscriptionQuotaWindow]
    public let dashboardURL: URL?
    public let nextResetAt: Date?
    /// Adapter-supplied secondary line shown under the plan name in
    /// Settings. Used when the adapter reached the API but the user
    /// has no active subscription (e.g. an upstream "no active
    /// coding plan" response) — the UI then shows the plan name +
    /// this note + dashboard link instead of an empty card.
    /// Adapters should localize this string themselves before
    /// returning it; the host renders it verbatim.
    public let note: String?

    public init(planName: String, quotas: [SubscriptionQuotaWindow], dashboardURL: URL?, nextResetAt: Date?, note: String? = nil) {
        self.planName = planName
        self.quotas = quotas
        self.dashboardURL = dashboardURL
        self.nextResetAt = nextResetAt
        self.note = note
    }
}

/// One quota dimension. `used / limit` map straight onto the existing
/// menu-bar progress UI; Anthropic's 5h/7d windows and GLM's
/// 5h/monthly windows both fit this shape.
public struct SubscriptionQuotaWindow: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let used: SubscriptionAmount
    public let limit: SubscriptionAmount?
    public let percentage: Double
    public let resetAt: Date?

    public init(id: String, title: String, used: SubscriptionAmount, limit: SubscriptionAmount?, percentage: Double, resetAt: Date?) {
        self.id = id
        self.title = title
        self.used = used
        self.limit = limit
        self.percentage = percentage
        self.resetAt = resetAt
    }
}

public struct SubscriptionAmount: Sendable, Codable, Equatable {
    public let value: Double
    public let unit: SubscriptionUnit

    public init(value: Double, unit: SubscriptionUnit) {
        self.value = value
        self.unit = unit
    }
}

public enum SubscriptionUnit: String, Sendable, Codable, Equatable {
    case tokens
    case dollars
    case credits
    case requests
}
