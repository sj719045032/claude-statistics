import SwiftUI

// MARK: - Quota Limit API Response

struct ZaiQuotaResponse: Codable {
    let code: Int
    let msg: String
    let data: ZaiQuotaData
    let success: Bool
}

struct ZaiQuotaData: Codable {
    let limits: [ZaiLimit]
    let level: String?
}

struct ZaiLimit: Codable {
    let type: String              // "TIME_LIMIT" or "TOKENS_LIMIT"
    let unit: Int                 // 5=monthly search, 3=5-hours, 6=weekly
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Double
    let nextResetTime: Int64?     // milliseconds since epoch
    let usageDetails: [ZaiUsageDetail]?

    enum CodingKeys: String, CodingKey {
        case type, unit, number, usage, currentValue, remaining, percentage
        case nextResetTime, usageDetails
    }
}

struct ZaiUsageDetail: Codable {
    let modelCode: String
    let usage: Int
}

// MARK: - Model Usage (Histogram) API Response

struct ZaiModelUsageResponse: Codable {
    let code: Int
    let msg: String
    let data: ZaiModelUsageData
    let success: Bool
}

struct ZaiModelUsageData: Codable {
    let xTime: [String?]
    let modelCallCount: [Int?]
    let tokensUsage: [Int?]
    let totalUsage: ZaiTotalUsage

    enum CodingKeys: String, CodingKey {
        case xTime = "x_time"
        case modelCallCount, tokensUsage, totalUsage
    }
}

struct ZaiTotalUsage: Codable {
    let totalModelCallCount: Int
    let totalTokensUsage: Int
}

// MARK: - Display Models

enum ZaiQuotaKind: String, Codable {
    case monthlySearch
    case fiveHours
    case weekly

    init(type: String, unit: Int) {
        switch (type, unit) {
        case ("TIME_LIMIT", 5):
            self = .monthlySearch
        case ("TOKENS_LIMIT", 3):
            self = .fiveHours
        default:
            self = .weekly
        }
    }

    init?(cacheKey: String?) {
        switch cacheKey {
        case "zai.monthlySearch":
            self = .monthlySearch
        case "zai.5hours":
            self = .fiveHours
        case "zai.weekly":
            self = .weekly
        default:
            return nil
        }
    }

    var title: LocalizedStringKey {
        LocalizedStringKey(titleKey)
    }

    var titleKey: String {
        switch self {
        case .monthlySearch:
            return "zai.monthlySearch"
        case .fiveHours:
            return "zai.5hours"
        case .weekly:
            return "zai.weekly"
        }
    }

    var isTokenLimit: Bool {
        self != .monthlySearch
    }
}

struct ZaiQuotaLimitDisplay {
    let kind: ZaiQuotaKind
    let percentage: Double
    let nextResetDate: Date?
    let timeUntilReset: TimeInterval?
    let usageDetails: [ZaiUsageDetail]?
    let usage: Int?
    let remaining: Int?

    var title: LocalizedStringKey {
        kind.title
    }
}

struct ZaiModelUsageDisplay {
    let points: [ZaiChartPoint]
    let totalCalls: Int
    let totalTokens: Int

    func chartPoints(for range: ZaiUsageRange, calendar: Calendar = .current) -> [ZaiChartPoint] {
        switch range {
        case .day:
            return points.sorted { $0.time < $1.time }
        case .week:
            let grouped = Dictionary(grouping: points) { point in
                calendar.startOfDay(for: point.time)
            }

            return grouped
                .map { day, points in
                    ZaiChartPoint(
                        time: day,
                        calls: points.reduce(0) { $0 + $1.calls },
                        tokens: points.reduce(0) { $0 + $1.tokens }
                    )
                }
                .sorted { $0.time < $1.time }
        }
    }
}

struct ZaiChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let calls: Int
    let tokens: Int
}
typealias ZaiTimeRange = ZaiUsageRange

// MARK: - Cache

struct ZaiUsageCacheFile: Codable {
    let fetchedAt: String
    let quotaLimits: [ZaiQuotaLimitCacheEntry]
    let modelUsage: ZaiModelUsageCacheData?

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case quotaLimits, modelUsage
    }
}

struct ZaiQuotaLimitCacheEntry: Codable {
    let kind: ZaiQuotaKind?
    let titleKey: String
    let percentage: Double
    let nextResetTime: Int64?
    let usageDetails: [ZaiUsageDetail]?
    let usage: Int?
    let remaining: Int?
}

struct ZaiModelUsageCacheData: Codable {
    let points: [ZaiChartPointCacheEntry]
    let totalCalls: Int
    let totalTokens: Int
}

struct ZaiChartPointCacheEntry: Codable {
    let time: Double   // timeIntervalSince1970
    let calls: Int
    let tokens: Int
}

// MARK: - Errors

enum ZaiError: LocalizedError {
    case noAPIKey
    case invalidURL
    case httpError(statusCode: Int)
    case decodingFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Z.ai API key not configured"
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP error: \(code)"
        case .decodingFailed(let detail): return "Decoding error: \(detail)"
        }
    }
}
