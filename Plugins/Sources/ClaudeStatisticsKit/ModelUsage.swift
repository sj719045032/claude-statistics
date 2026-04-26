import Foundation

/// Per-model rollup row used in the host's stats / share-card / usage
/// surfaces. Plugins don't typically build these directly — the host
/// composes them from `SessionStats.modelBreakdown` plus the host's
/// `ModelPricing` table. The type lives in the SDK so any plugin that
/// wants to render its own pre-computed cost summary can produce
/// `ModelUsage` rows the host knows how to consume.
public struct ModelUsage: Identifiable, Sendable {
    public let model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreation5mTokens: Int
    public var cacheCreation1hTokens: Int
    public var cacheCreationTotalTokens: Int
    public var cacheReadTokens: Int
    public var cost: Double
    public var sessionCount: Int
    public var messageCount: Int
    public var isEstimated: Bool

    public var id: String { model }
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTotalTokens + cacheReadTokens
    }

    public init(
        model: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        cacheCreationTotalTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cost: Double = 0,
        sessionCount: Int = 0,
        messageCount: Int = 0,
        isEstimated: Bool = false
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheCreationTotalTokens = cacheCreationTotalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cost = cost
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.isEstimated = isEstimated
    }
}
