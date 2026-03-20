import Foundation

struct UsageData: Codable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case extraUsage = "extra_usage"
    }
}

struct UsageWindow: Codable, Equatable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }

    var timeUntilReset: TimeInterval? {
        guard let date = resetsAtDate else { return nil }
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }
}

struct ExtraUsage: Codable, Equatable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

struct UsageCacheFile: Codable {
    let fetchedAt: String
    let data: UsageData

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case data
    }
}

/// Claude HUD plugin cache format (~/.claude/plugins/claude-hud/.usage-cache.json)
struct HudUsageCache: Codable {
    let data: HudUsageData?
    let timestamp: Double?
    let lastGoodData: HudUsageData?
}

struct HudUsageData: Codable {
    let planName: String?
    let fiveHour: Double?
    let sevenDay: Double?
    let fiveHourResetAt: String?
    let sevenDayResetAt: String?

    func toUsageData() -> UsageData {
        UsageData(
            fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: fiveHourResetAt ?? "") },
            sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: sevenDayResetAt ?? "") },
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            extraUsage: nil
        )
    }
}

// MARK: - User Profile

struct UserProfile: Codable {
    let account: ProfileAccount?
    let organization: ProfileOrganization?
}

struct ProfileAccount: Codable {
    let fullName: String?
    let displayName: String?
    let email: String?
    let hasClaudeMax: Bool?
    let hasClaudePro: Bool?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case displayName = "display_name"
        case email
        case hasClaudeMax = "has_claude_max"
        case hasClaudePro = "has_claude_pro"
    }
}

struct ProfileOrganization: Codable {
    let name: String?
    let organizationType: String?
    let rateLimitTier: String?
    let subscriptionStatus: String?

    enum CodingKeys: String, CodingKey {
        case name
        case organizationType = "organization_type"
        case rateLimitTier = "rate_limit_tier"
        case subscriptionStatus = "subscription_status"
    }

    var orgTypeDisplayName: String {
        switch organizationType {
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        case "claude_pro": return "Pro"
        default: return organizationType?.replacingOccurrences(of: "claude_", with: "").capitalized ?? "–"
        }
    }

    var tierDisplayName: String {
        guard let tier = rateLimitTier else { return "–" }
        if tier.contains("claude_max_5x") { return "Max 5x" }
        if tier.contains("claude_max") { return "Max" }
        if tier.contains("claude_pro") { return "Pro" }
        return tier.replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

// MARK: - Usage API Response

struct UsageAPIResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case extraUsage = "extra_usage"
    }

    var asUsageData: UsageData {
        UsageData(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOauthApps: sevenDayOauthApps,
            sevenDayOpus: sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet,
            sevenDayCowork: sevenDayCowork,
            extraUsage: extraUsage
        )
    }
}
