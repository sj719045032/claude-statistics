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
    /// Local-JSONL trend chart configuration the host should render
    /// alongside the quota progress bars. Adapters that have a
    /// matching local-model footprint (e.g. GLM Coding Plan → JSONL
    /// rows tagged `glm-*`) point each window's `subscriptionQuotaID`
    /// at one of `quotas` so the chart's window end aligns with the
    /// upstream reset time. Excluded from `Codable` because
    /// `Calendar.Component` doesn't conform — the host never persists
    /// `SubscriptionInfo`, so this is in-memory only.
    public let localTrendWindows: [ProviderUsageTrendPresentation]

    public init(
        planName: String,
        quotas: [SubscriptionQuotaWindow],
        dashboardURL: URL?,
        nextResetAt: Date?,
        note: String? = nil,
        localTrendWindows: [ProviderUsageTrendPresentation] = []
    ) {
        self.planName = planName
        self.quotas = quotas
        self.dashboardURL = dashboardURL
        self.nextResetAt = nextResetAt
        self.note = note
        self.localTrendWindows = localTrendWindows
    }

    private enum CodingKeys: String, CodingKey {
        case planName, quotas, dashboardURL, nextResetAt, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.planName = try c.decode(String.self, forKey: .planName)
        self.quotas = try c.decode([SubscriptionQuotaWindow].self, forKey: .quotas)
        self.dashboardURL = try c.decodeIfPresent(URL.self, forKey: .dashboardURL)
        self.nextResetAt = try c.decodeIfPresent(Date.self, forKey: .nextResetAt)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
        self.localTrendWindows = []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(planName, forKey: .planName)
        try c.encode(quotas, forKey: .quotas)
        try c.encodeIfPresent(dashboardURL, forKey: .dashboardURL)
        try c.encodeIfPresent(nextResetAt, forKey: .nextResetAt)
        try c.encodeIfPresent(note, forKey: .note)
    }

    public static func == (lhs: SubscriptionInfo, rhs: SubscriptionInfo) -> Bool {
        lhs.planName == rhs.planName
            && lhs.quotas == rhs.quotas
            && lhs.dashboardURL == rhs.dashboardURL
            && lhs.nextResetAt == rhs.nextResetAt
            && lhs.note == rhs.note
            && lhs.localTrendWindows == rhs.localTrendWindows
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
    /// Total length of the window (e.g. `5 * 3600` for a 5-hour
    /// bucket, `7 * 86400` for a weekly bucket). When set together
    /// with `resetAt`, the host renders an "exhausts in …" estimate
    /// next to the title using linear extrapolation
    /// (`utilization / elapsed`). `nil` opts out — adapters whose
    /// upstream API doesn't reveal the window length should leave
    /// it unset so the host doesn't fabricate a duration.
    public let windowDuration: TimeInterval?

    public init(
        id: String,
        title: String,
        used: SubscriptionAmount,
        limit: SubscriptionAmount?,
        percentage: Double,
        resetAt: Date?,
        windowDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.used = used
        self.limit = limit
        self.percentage = percentage
        self.resetAt = resetAt
        self.windowDuration = windowDuration
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
