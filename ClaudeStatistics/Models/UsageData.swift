import Foundation
import ClaudeStatisticsKit

// `UsageData`, `UsageWindow`, `ProviderUsageBucket`, `ExtraUsage`,
// `UserProfile`, `ProfileAccount`, `ProfileOrganization` and
// `UsageCacheFile` live in `ClaudeStatisticsKit`. The host-bundle
// types below are Claude-specific cache and API-response wrappers
// that don't belong in the cross-plugin SDK.

struct ClaudeUsageCacheFile: Codable {
    let fetchedAt: String
    let data: UsageData
    let sources: ClaudeUsageCacheSources?

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case data
        case sources
    }
}

struct ClaudeUsageCacheSources: Codable {
    let api: ClaudeUsageCacheSourceSnapshot?
    let stdin: ClaudeUsageCacheSourceSnapshot?
}

struct ClaudeUsageCacheSourceSnapshot: Codable {
    let fetchedAt: String
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

// MARK: - Usage API Response (Claude-specific)

struct UsageAPIResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayFable: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let limits: [ClaudeUsageLimit]?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayFable = "seven_day_fable"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case limits
        case extraUsage = "extra_usage"
    }

    private var resolvedSevenDayFable: UsageWindow? {
        if let sevenDayFable { return sevenDayFable }

        guard let limit = limits?.first(where: { limit in
            guard let displayName = limit.scope?.model?.displayName?.lowercased(),
                  displayName.contains("fable") else {
                return false
            }
            return limit.group?.lowercased() == "weekly"
                || limit.kind?.lowercased().contains("weekly") == true
        }), let percent = limit.percent else {
            return nil
        }

        return UsageWindow(utilization: percent, resetsAt: limit.resetsAt)
    }

    private var fableBucket: ProviderUsageBucket? {
        guard let window = resolvedSevenDayFable else { return nil }
        return ProviderUsageBucket(
            id: "claude-seven-day-fable",
            title: "Fable 5",
            remainingPercentage: max(0, min(100, 100 - window.utilization)),
            resetsAt: window.resetsAt
        )
    }

    var asUsageData: UsageData {
        UsageData(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOauthApps: sevenDayOauthApps,
            sevenDayOpus: sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet,
            sevenDayCowork: sevenDayCowork,
            providerBuckets: fableBucket.map { [$0] },
            extraUsage: extraUsage
        )
    }
}

struct ClaudeUsageLimit: Codable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: ClaudeUsageLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
    }
}

struct ClaudeUsageLimitScope: Codable {
    let model: ClaudeUsageLimitModel?
}

struct ClaudeUsageLimitModel: Codable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}
