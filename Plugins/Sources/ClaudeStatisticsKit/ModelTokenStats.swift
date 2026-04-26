import Foundation

/// Per-model token totals emitted by transcript parsers as part of
/// `SessionStats.modelBreakdown`. Plugins build these per
/// `(model, 5-min bucket)` pair so the host can compute hour / day /
/// session aggregates from the same source of truth.
public struct ModelTokenStats: Codable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreation5mTokens: Int
    public var cacheCreation1hTokens: Int
    public var cacheCreationTotalTokens: Int
    public var cacheReadTokens: Int
    public var messageCount: Int

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTotalTokens + cacheReadTokens
    }

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        cacheCreationTotalTokens: Int = 0,
        cacheReadTokens: Int = 0,
        messageCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheCreationTotalTokens = cacheCreationTotalTokens
        self.cacheReadTokens = cacheReadTokens
        self.messageCount = messageCount
    }
}
