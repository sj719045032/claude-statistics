import Foundation
import ClaudeStatisticsKit

/// Host-side cost helpers for `DaySlice`. Plugins emit pure-data
/// `DaySlice` instances (token counts, tool counts, per-model
/// breakdown); the host attaches cost computation that needs the
/// `ModelPricing` table.
extension DaySlice {
    var estimatedCost: Double {
        modelBreakdown.reduce(0.0) { total, entry in
            total + ModelPricing.estimateCost(
                model: entry.key,
                inputTokens: entry.value.inputTokens,
                outputTokens: entry.value.outputTokens,
                cacheCreation5mTokens: entry.value.cacheCreation5mTokens,
                cacheCreation1hTokens: entry.value.cacheCreation1hTokens,
                cacheCreationTotalTokens: entry.value.cacheCreationTotalTokens,
                cacheReadTokens: entry.value.cacheReadTokens
            )
        }
    }

    var isCostEstimated: Bool {
        modelBreakdown.keys.contains { !ModelPricing.shared.isExactMatch(for: $0) }
    }
}
