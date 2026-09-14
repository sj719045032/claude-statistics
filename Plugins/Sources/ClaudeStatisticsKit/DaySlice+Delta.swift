import Foundation

extension DaySlice {
    /// Retract a previous contribution before applying its replacement. Unlike
    /// clamping at zero, signed arithmetic makes duplicate-counting bugs visible.
    public mutating func subtract(_ other: DaySlice) {
        totalInputTokens -= other.totalInputTokens
        totalOutputTokens -= other.totalOutputTokens
        cacheCreation5mTokens -= other.cacheCreation5mTokens
        cacheCreation1hTokens -= other.cacheCreation1hTokens
        cacheCreationTotalTokens -= other.cacheCreationTotalTokens
        cacheReadTokens -= other.cacheReadTokens
        messageCount -= other.messageCount
        for (tool, count) in other.toolUseCounts {
            toolUseCounts[tool, default: 0] -= count
            if toolUseCounts[tool] == 0 { toolUseCounts.removeValue(forKey: tool) }
        }
        for (model, value) in other.modelBreakdown {
            var previous = modelBreakdown[model, default: ModelTokenStats()]
            previous.inputTokens -= value.inputTokens
            previous.outputTokens -= value.outputTokens
            previous.cacheCreation5mTokens -= value.cacheCreation5mTokens
            previous.cacheCreation1hTokens -= value.cacheCreation1hTokens
            previous.cacheCreationTotalTokens -= value.cacheCreationTotalTokens
            previous.cacheReadTokens -= value.cacheReadTokens
            previous.messageCount -= value.messageCount
            modelBreakdown[model] = previous
            if previous.inputTokens == 0, previous.outputTokens == 0,
               previous.cacheCreation5mTokens == 0, previous.cacheCreation1hTokens == 0,
               previous.cacheCreationTotalTokens == 0, previous.cacheReadTokens == 0,
               previous.messageCount == 0 { modelBreakdown.removeValue(forKey: model) }
        }
    }

    public var isEmpty: Bool {
        totalInputTokens == 0 && totalOutputTokens == 0 && cacheCreation5mTokens == 0 &&
        cacheCreation1hTokens == 0 && cacheCreationTotalTokens == 0 && cacheReadTokens == 0 &&
        messageCount == 0 && toolUseCounts.isEmpty && modelBreakdown.isEmpty
    }
}
