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
            providerBuckets: nil,
            extraUsage: extraUsage
        )
    }
}
