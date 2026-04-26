import Foundation
import ClaudeStatisticsKit

/// Host-side cost helpers for `SessionStats`. The SDK's pure-data
/// version doesn't know about `ModelPricing` or `ModelUsage`; this
/// extension wires those in.
extension SessionStats {
    /// Whether the cost is an estimate (no exact pricing for this model).
    var isCostEstimated: Bool {
        !ModelPricing.shared.isExactMatch(for: model)
    }

    /// Estimated cost in USD based on model pricing.
    var estimatedCost: Double {
        // If we have per-model breakdown, sum each model's cost accurately.
        if !modelBreakdown.isEmpty {
            return modelBreakdown.reduce(0.0) { total, entry in
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
        // Fallback: no breakdown, use session-level model.
        return ModelPricing.estimateCost(
            model: model,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            cacheCreation5mTokens: cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens,
            cacheCreationTotalTokens: cacheCreationTotalTokens,
            cacheReadTokens: cacheReadTokens
        )
    }

    /// Per-model rollup as `ModelUsage` rows for the host's stats /
    /// share-card surfaces.
    var asModelUsages: [ModelUsage] {
        if modelBreakdown.isEmpty {
            var u = ModelUsage(model: model)
            u.inputTokens = totalInputTokens
            u.outputTokens = totalOutputTokens
            u.cacheCreation5mTokens = cacheCreation5mTokens
            u.cacheCreation1hTokens = cacheCreation1hTokens
            u.cacheCreationTotalTokens = cacheCreationTotalTokens
            u.cacheReadTokens = cacheReadTokens
            u.cost = estimatedCost
            u.sessionCount = 1
            u.isEstimated = isCostEstimated
            return [u]
        }
        return modelBreakdown.map { (key, mts) in
            var u = ModelUsage(model: key)
            u.inputTokens = mts.inputTokens
            u.outputTokens = mts.outputTokens
            u.cacheCreation5mTokens = mts.cacheCreation5mTokens
            u.cacheCreation1hTokens = mts.cacheCreation1hTokens
            u.cacheCreationTotalTokens = mts.cacheCreationTotalTokens
            u.cacheReadTokens = mts.cacheReadTokens
            u.messageCount = mts.messageCount
            u.cost = ModelPricing.estimateCost(
                model: key,
                inputTokens: mts.inputTokens,
                outputTokens: mts.outputTokens,
                cacheCreation5mTokens: mts.cacheCreation5mTokens,
                cacheCreation1hTokens: mts.cacheCreation1hTokens,
                cacheCreationTotalTokens: mts.cacheCreationTotalTokens,
                cacheReadTokens: mts.cacheReadTokens
            )
            u.sessionCount = 1
            u.isEstimated = !ModelPricing.shared.isExactMatch(for: key)
            return u
        }.sorted { $0.totalTokens > $1.totalTokens }
    }
}
