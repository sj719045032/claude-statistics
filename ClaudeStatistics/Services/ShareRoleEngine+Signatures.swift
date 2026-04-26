import Foundation

// MARK: - Signature Heuristics

extension ShareRoleEngine {
    static func hasModerateToolSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.toolUseCount >= 5 && metrics.toolUsePerMessage >= 0.18 && metrics.toolCategoryCount >= 2
        case .weekly:
            return metrics.toolUseCount >= 10 && metrics.toolUsePerMessage >= 0.18 && metrics.toolCategoryCount >= 2
        case .monthly, .all:
            return metrics.toolUseCount >= 36 && metrics.toolUsePerMessage >= 0.22 && metrics.toolCategoryCount >= 3
        }
    }

    static func hasStrongToolSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.toolUseCount >= 8 && metrics.toolUsePerMessage >= 0.28 && metrics.toolCategoryCount >= 2
        case .weekly:
            return metrics.toolUseCount >= 18 && metrics.toolUsePerMessage >= 0.26 && metrics.toolCategoryCount >= 3
        case .monthly, .all:
            return metrics.toolUseCount >= 72 && metrics.toolUsePerMessage >= 0.32 && metrics.toolCategoryCount >= 4
        }
    }

    static func hasModerateContextSignature(_ metrics: ShareMetrics) -> Bool {
        let signalCount = contextSignalCount(metrics, strong: false)
        switch metrics.scope {
        case .daily:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 18 || cacheReadRatio(metrics) >= 0.24
        case .weekly:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 20 || cacheReadRatio(metrics) >= 0.26
        case .monthly, .all:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 22 || cacheReadRatio(metrics) >= 0.28
        }
    }

    static func hasStrongContextSignature(_ metrics: ShareMetrics) -> Bool {
        let signalCount = contextSignalCount(metrics, strong: true)
        switch metrics.scope {
        case .daily:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 24 || cacheReadRatio(metrics) >= 0.32
        case .weekly:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 26 || cacheReadRatio(metrics) >= 0.34
        case .monthly, .all:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 28 || cacheReadRatio(metrics) >= 0.36
        }
    }

    static func contextSignalCount(_ metrics: ShareMetrics, strong: Bool) -> Int {
        let cacheRatio = cacheReadRatio(metrics)
        let averageContextThreshold: Double
        let cacheTokenThreshold: Int
        let cacheRatioThreshold: Double
        let longSessionThreshold: Double
        let averageTokensThreshold: Double

        switch (metrics.scope, strong) {
        case (.daily, false):
            averageContextThreshold = 8
            cacheTokenThreshold = 60_000
            cacheRatioThreshold = 0.10
            longSessionThreshold = 0.25
            averageTokensThreshold = 60_000
        case (.daily, true):
            averageContextThreshold = 14
            cacheTokenThreshold = 140_000
            cacheRatioThreshold = 0.18
            longSessionThreshold = 0.40
            averageTokensThreshold = 140_000
        case (.weekly, false):
            averageContextThreshold = 9
            cacheTokenThreshold = 100_000
            cacheRatioThreshold = 0.08
            longSessionThreshold = 0.24
            averageTokensThreshold = 70_000
        case (.weekly, true):
            averageContextThreshold = 15
            cacheTokenThreshold = 220_000
            cacheRatioThreshold = 0.16
            longSessionThreshold = 0.38
            averageTokensThreshold = 160_000
        case (.monthly, false), (.all, false):
            averageContextThreshold = 10
            cacheTokenThreshold = 180_000
            cacheRatioThreshold = 0.07
            longSessionThreshold = 0.22
            averageTokensThreshold = 80_000
        case (.monthly, true), (.all, true):
            averageContextThreshold = 16
            cacheTokenThreshold = 360_000
            cacheRatioThreshold = 0.14
            longSessionThreshold = 0.36
            averageTokensThreshold = 180_000
        }

        return [
            metrics.averageContextUsagePercent >= averageContextThreshold,
            metrics.cacheReadTokens >= cacheTokenThreshold,
            cacheRatio >= cacheRatioThreshold,
            metrics.longSessionRatio >= longSessionThreshold,
            metrics.averageTokensPerSession >= averageTokensThreshold
        ]
        .filter { $0 }
        .count
    }

    static func hasModerateNightSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.nightTokenRatio >= 0.32 && metrics.nightSessionCount >= 1
        case .weekly:
            return metrics.nightTokenRatio >= 0.24 && metrics.nightSessionCount >= 2
        case .monthly, .all:
            return metrics.nightTokenRatio >= 0.22 && metrics.nightSessionCount >= 3
        }
    }

    static func hasStrongNightSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.nightTokenRatio >= 0.5 && metrics.nightSessionCount >= 1
        case .weekly:
            return metrics.nightTokenRatio >= 0.32 && metrics.nightSessionCount >= 2
        case .monthly, .all:
            return metrics.nightTokenRatio >= 0.3 && metrics.nightSessionCount >= 4
        }
    }

    static func hasModerateMultiModelSignature(_ metrics: ShareMetrics) -> Bool {
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        if metrics.providerCount >= 2 {
            return adjustedModelCount >= 3 && metrics.modelEntropy >= 0.34
        }
        return metrics.modelCount >= 2 && metrics.modelEntropy >= 0.30
    }

    static func hasStrongMultiModelSignature(_ metrics: ShareMetrics) -> Bool {
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        if metrics.providerCount >= 2 {
            return adjustedModelCount >= 5 && metrics.modelEntropy >= 0.50
        }
        return metrics.modelCount >= 2 && metrics.modelEntropy >= 0.45
    }

    static func providerAdjustedModelCount(_ metrics: ShareMetrics) -> Int {
        // Multi-provider cards naturally contain one or more models per provider. Count only
        // model variety beyond the provider split so "All AI" does not default to this role.
        max(0, metrics.modelCount - max(metrics.providerCount - 1, 0))
    }

    static func cacheReadRatio(_ metrics: ShareMetrics) -> Double {
        guard metrics.totalTokens > 0 else { return 0 }
        return Double(metrics.cacheReadTokens) / Double(metrics.totalTokens)
    }

    static func hasStrongSprintSignature(_ metrics: ShareMetrics) -> Bool {
        if metrics.scope == .daily { return false }
        return metrics.singleDayPeakRatio >= 0.4 || metrics.peakFiveMinuteTokens >= 80_000
    }

    static func hasStrongEfficiencySignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.totalTokens >= 400_000 &&
                metrics.totalCost >= 1.2 &&
                metrics.tokensPerDollar >= 220_000 &&
                metrics.messagesPerDollar >= 10
        case .weekly, .monthly, .all:
            return metrics.totalTokens >= 500_000 &&
                metrics.totalCost >= 1.0 &&
                metrics.tokensPerDollar >= 220_000 &&
                metrics.messagesPerDollar >= 10 &&
                metrics.averageTokensPerSession >= 20_000
        }
    }
}
