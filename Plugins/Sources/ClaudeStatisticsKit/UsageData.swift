import Foundation

/// Top-level usage snapshot a Provider plugin returns from its
/// `UsageProvider.refreshSnapshot()`. Carries either time-window
/// utilisation (Claude / Codex 5-hour + 7-day) or quota buckets
/// (Gemini), plus optional extra-usage info for paid tiers.
public struct UsageData: Codable, Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let sevenDayOauthApps: UsageWindow?
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let sevenDayCowork: UsageWindow?
    public let providerBuckets: [ProviderUsageBucket]?
    public let extraUsage: ExtraUsage?

    public init(
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil,
        sevenDayOauthApps: UsageWindow? = nil,
        sevenDayOpus: UsageWindow? = nil,
        sevenDaySonnet: UsageWindow? = nil,
        sevenDayCowork: UsageWindow? = nil,
        providerBuckets: [ProviderUsageBucket]? = nil,
        extraUsage: ExtraUsage? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOauthApps = sevenDayOauthApps
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayCowork = sevenDayCowork
        self.providerBuckets = providerBuckets
        self.extraUsage = extraUsage
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case providerBuckets = "provider_buckets"
        case extraUsage = "extra_usage"
    }
}

/// One quota bucket (e.g. Gemini's per-model-family quotas).
public struct ProviderUsageBucket: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let remainingPercentage: Double
    public let resetsAt: String?
    public let remainingAmount: Double?
    public let limitAmount: Double?
    public let unit: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        remainingPercentage: Double,
        resetsAt: String? = nil,
        remainingAmount: Double? = nil,
        limitAmount: Double? = nil,
        unit: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.remainingPercentage = remainingPercentage
        self.resetsAt = resetsAt
        self.remainingAmount = remainingAmount
        self.limitAmount = limitAmount
        self.unit = unit
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case remainingPercentage = "remaining_percentage"
        case resetsAt = "resets_at"
        case remainingAmount = "remaining_amount"
        case limitAmount = "limit_amount"
        case unit
    }

    public var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }

    public var timeUntilReset: TimeInterval? {
        guard let resetsAtDate else { return nil }
        let interval = resetsAtDate.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }
}

/// One time-window slice of utilization (Claude / Codex 5h or 7d).
public struct UsageWindow: Codable, Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: String?

    public init(utilization: Double, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let raw: Date?
        if let date = formatter.date(from: resetsAt) {
            raw = date
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            raw = formatter.date(from: resetsAt)
        }
        // Truncate to minute — removes fractional seconds that cause boundary misalignment
        guard let date = raw else { return nil }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return cal.date(from: comps) ?? date
    }

    public var timeUntilReset: TimeInterval? {
        guard let date = resetsAtDate else { return nil }
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }
}

/// Extra-usage / overage info for paid tiers (Claude Pro / Max).
public struct ExtraUsage: Codable, Equatable, Sendable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?

    public init(
        isEnabled: Bool? = nil,
        monthlyLimit: Double? = nil,
        usedCredits: Double? = nil,
        utilization: Double? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}
