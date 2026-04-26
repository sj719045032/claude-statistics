import Foundation

/// One snapshot of a provider's usage state at a point in time, paired
/// with its fetch timestamp so the host can render "as of N seconds
/// ago" without having to track its own clock alongside the cached
/// data. Plugins return one of these from
/// `UsageProvider.refreshSnapshot()`.
public struct ProviderUsageSnapshot: Sendable {
    public let data: UsageData
    public let fetchedAt: Date

    public init(data: UsageData, fetchedAt: Date) {
        self.data = data
        self.fetchedAt = fetchedAt
    }
}
