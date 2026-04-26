import Foundation

/// Per-bucket aggregation of tokens, tools, and per-model breakdown.
/// `SessionStats` keys these by 5-minute boundary in local time and
/// derives every coarser granularity (hour, day, totals) from the
/// same dictionary so plugin output stays consistent across views.
///
/// The cost-estimation getters (`estimatedCost`, `isCostEstimated`)
/// live as a host-side extension because they need the host's
/// `ModelPricing` table. Plugins emit `DaySlice` instances containing
/// only token counts + tool counts + per-model breakdowns.
public struct DaySlice: Codable, Sendable {
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var cacheCreation5mTokens: Int
    public var cacheCreation1hTokens: Int
    public var cacheCreationTotalTokens: Int
    public var cacheReadTokens: Int
    public var messageCount: Int
    public var toolUseCounts: [String: Int]
    public var modelBreakdown: [String: ModelTokenStats]

    public var toolUseTotal: Int { toolUseCounts.values.reduce(0, +) }
    public var totalTokens: Int {
        totalInputTokens + totalOutputTokens + cacheCreationTotalTokens + cacheReadTokens
    }

    public init(
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        cacheCreationTotalTokens: Int = 0,
        cacheReadTokens: Int = 0,
        messageCount: Int = 0,
        toolUseCounts: [String: Int] = [:],
        modelBreakdown: [String: ModelTokenStats] = [:]
    ) {
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheCreationTotalTokens = cacheCreationTotalTokens
        self.cacheReadTokens = cacheReadTokens
        self.messageCount = messageCount
        self.toolUseCounts = toolUseCounts
        self.modelBreakdown = modelBreakdown
    }

    public mutating func merge(_ other: DaySlice) {
        totalInputTokens += other.totalInputTokens
        totalOutputTokens += other.totalOutputTokens
        cacheCreation5mTokens += other.cacheCreation5mTokens
        cacheCreation1hTokens += other.cacheCreation1hTokens
        cacheCreationTotalTokens += other.cacheCreationTotalTokens
        cacheReadTokens += other.cacheReadTokens
        messageCount += other.messageCount
        for (tool, count) in other.toolUseCounts {
            toolUseCounts[tool, default: 0] += count
        }
        for (model, mts) in other.modelBreakdown {
            var existing = modelBreakdown[model, default: ModelTokenStats()]
            existing.inputTokens += mts.inputTokens
            existing.outputTokens += mts.outputTokens
            existing.cacheCreation5mTokens += mts.cacheCreation5mTokens
            existing.cacheCreation1hTokens += mts.cacheCreation1hTokens
            existing.cacheCreationTotalTokens += mts.cacheCreationTotalTokens
            existing.cacheReadTokens += mts.cacheReadTokens
            existing.messageCount += mts.messageCount
            modelBreakdown[model] = existing
        }
    }
}
