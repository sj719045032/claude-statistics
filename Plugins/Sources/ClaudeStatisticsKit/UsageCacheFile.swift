import Foundation

/// Generic on-disk cache wrapper for a `UsageData` snapshot. Plugins
/// (Gemini / future Codex) and host services persist usage between
/// launches by encoding this struct to JSON.
public struct UsageCacheFile: Codable, Sendable {
    public let fetchedAt: String
    public let data: UsageData

    public init(fetchedAt: String, data: UsageData) {
        self.fetchedAt = fetchedAt
        self.data = data
    }

    public enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case data
    }
}
