import Foundation

// MARK: - Role Scoring

extension ShareRoleEngine {
    static func vibeCodingKingScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        if metrics.scope == .all {
            return longHorizonVibeCodingKingScore(metrics: metrics, baseline: baseline)
        }

        var score =
            0.28 * countScore(Double(metrics.toolUseCount), baseline?.toolUseCount) +
            0.24 * countScore(Double(metrics.sessionCount), baseline?.sessionCount) +
            0.16 * countScore(Double(metrics.projectCount), baseline?.projectCount) +
            0.15 * countScore(Double(metrics.messageCount), baseline?.messageCount) +
            0.07 * ratioScore(metrics.activeDayCoverage, baseline?.activeDayCoverage) +
            0.10 * countScore(metrics.averageTokensPerSession, baseline?.averageTokensPerSession)
        if metrics.sessionCount >= 8 && metrics.toolUseCount >= 40 {
            score += 0.08
        }
        if hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.16
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.10
        }
        return min(score, 1.2)
    }

    static func toolSummonerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateToolSignature(metrics) else { return 0 }
        var score =
            0.52 * countScore(metrics.toolUsePerMessage, baseline?.toolUsePerMessage) +
            0.30 * countScore(Double(metrics.toolCategoryCount), baseline?.toolCategoryCount) +
            0.18 * countScore(Double(metrics.toolUseCount), baseline?.toolUseCount)
        if hasStrongToolSignature(metrics) {
            score += 0.12
        }
        if hasModerateToolSignature(metrics) {
            score += metrics.scope == .monthly || metrics.scope == .all ? 0.03 : 0.06
        }
        if metrics.scope == .monthly || metrics.scope == .all {
            score -= 0.06
        }
        if hasModerateContextSignature(metrics) || hasModerateMultiModelSignature(metrics) {
            score -= 0.06
        }
        return min(score, 1.2)
    }

    static func contextBeastTamerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateContextSignature(metrics) else { return 0 }
        var score =
            0.32 * ratioScore(metrics.averageContextUsagePercent / 100.0, baseline.map { $0.averageContextUsagePercent / 100.0 }) +
            0.22 * countScore(Double(metrics.cacheReadTokens), baseline?.cacheReadTokens) +
            0.24 * ratioScore(metrics.longSessionRatio, baseline?.longSessionRatio) +
            0.14 * ratioScore(cacheReadRatio(metrics), baseline.map(cacheReadRatio)) +
            0.08 * countScore(metrics.averageTokensPerSession, baseline?.averageTokensPerSession)
        if hasStrongContextSignature(metrics) {
            score += 0.12
        }
        if hasModerateContextSignature(metrics) {
            score += 0.04
        }
        if hasModerateToolSignature(metrics) || hasModerateMultiModelSignature(metrics) || hasModerateNightSignature(metrics) {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    static func nightShiftEngineerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateNightSignature(metrics) else { return 0 }
        var score =
            0.50 * ratioScore(metrics.nightTokenRatio, baseline?.nightTokenRatio) +
            0.30 * ratioScore(metrics.nightSessionRatio, baseline?.nightSessionRatio) +
            0.20 * countScore(Double(metrics.nightSessionCount), baseline?.nightSessionCount)
        if hasStrongNightSignature(metrics) {
            score += 0.18
        }
        if hasModerateNightSignature(metrics) {
            score += 0.08
        }
        return min(score, 1.2)
    }

    static func multiModelDirectorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateMultiModelSignature(metrics) else { return 0 }
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        let baselineAdjustedModelCount = baseline.map(providerAdjustedModelCount)
        var score =
            0.12 * rangeScore(Double(metrics.providerCount), min: 1, max: 3) +
            0.46 * countScore(Double(adjustedModelCount), baselineAdjustedModelCount) +
            0.32 * ratioScore(metrics.modelEntropy, baseline?.modelEntropy) +
            0.10 * rangeScore(Double(metrics.modelCount), min: 2, max: 10)
        if hasStrongMultiModelSignature(metrics) {
            score += 0.16
        }
        if hasModerateMultiModelSignature(metrics) {
            score += 0.10
        }
        if metrics.providerCount >= 2 && adjustedModelCount < 3 {
            score -= 0.22
        }
        return min(score, 1.2)
    }

    static func sprintHackerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.scope != .daily else { return 0 }
        let burstiness = metrics.totalTokens > 0 ? Double(metrics.peakFiveMinuteTokens) / Double(metrics.totalTokens) : 0
        let baselineBurstiness = baseline.map { $0.totalTokens > 0 ? Double($0.peakFiveMinuteTokens) / Double($0.totalTokens) : 0 }
        let score =
            0.40 * ratioScore(metrics.singleDayPeakRatio, baseline?.singleDayPeakRatio) +
            0.35 * countScore(Double(metrics.peakFiveMinuteTokens), baseline?.peakFiveMinuteTokens) +
            0.25 * ratioScore(burstiness, baselineBurstiness)
        if hasStrongSprintSignature(metrics) {
            return min(score + 0.16, 1.2)
        }
        return min(score, 1.2)
    }

    static func fullStackPathfinderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        if metrics.scope == .all {
            return longHorizonFullStackPathfinderScore(metrics: metrics, baseline: baseline)
        }

        var score =
            0.38 * countScore(Double(metrics.projectCount), baseline?.projectCount) +
            0.30 * ratioScore(metrics.activeDayCoverage, baseline?.activeDayCoverage) +
            0.18 * (1.0 - ratioScore(metrics.singleDayPeakRatio, baseline?.singleDayPeakRatio)) +
            0.14 * countScore(Double(metrics.sessionCount), baseline?.sessionCount)
        if metrics.projectCount >= 4 && metrics.activeDayCoverage >= 0.5 {
            score += 0.08
        }
        if hasStrongToolSignature(metrics) || hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongSprintSignature(metrics) {
            score -= 0.18
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    static func efficientOperatorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.totalCost >= 0.8,
              metrics.totalTokens >= 250_000,
              metrics.sessionCount >= 3,
              metrics.estimatedCostRatio <= 0.7 else {
            return 0
        }
        var score =
            0.28 * countScore(metrics.tokensPerDollar, baseline?.tokensPerDollar) +
            0.22 * countScore(metrics.messagesPerDollar, baseline?.messagesPerDollar) +
            0.18 * (1.0 - countScore(metrics.costPerSession, baseline?.costPerSession)) +
            0.20 * countScore(Double(metrics.totalTokens), baseline?.totalTokens) +
            0.12 * countScore(Double(metrics.sessionCount), baseline?.sessionCount)
        if hasStrongEfficiencySignature(metrics) {
            score += 0.10
        }
        if hasStrongToolSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongNightSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.16
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.06
        }
        return min(score, 1.2)
    }

    static func steadyBuilderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.30 * ratioScore(metrics.activeDayCoverage, baseline?.activeDayCoverage) +
            0.25 * countScore(Double(metrics.sessionCount), baseline?.sessionCount) +
            0.20 * countScore(Double(metrics.messageCount), baseline?.messageCount) +
            0.15 * countScore(Double(metrics.projectCount), baseline?.projectCount) +
            0.10 * (1.0 - ratioScore(metrics.nightTokenRatio, baseline?.nightTokenRatio))
        if distinctiveSignatureCount(metrics) > 0 {
            score -= 0.10
        }
        if distinctiveSignatureCount(metrics) > 1 {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    static func longHorizonVibeCodingKingScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.26 * rangeScore(metrics.toolUsePerMessage, min: 0.16, max: 0.58) +
            0.18 * rangeScore(Double(metrics.toolCategoryCount), min: 3, max: 9) +
            0.16 * rangeScore(Double(metrics.projectCount), min: 4, max: 20) +
            0.16 * rangeScore(Double(metrics.sessionCount), min: 12, max: 180) +
            0.12 * rangeScore(Double(metrics.messageCount), min: 160, max: 8_000) +
            0.12 * rangeScore(metrics.averageTokensPerSession, min: 20_000, max: 260_000)

        score += 0.04 * liftScore(metrics.toolUsePerMessage, baseline?.toolUsePerMessage)

        if metrics.toolUsePerMessage < 0.18 || metrics.toolCategoryCount < 3 {
            score -= 0.18
        }
        if hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.14
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.14
        }
        return min(score, 1.2)
    }

    static func longHorizonFullStackPathfinderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.34 * rangeScore(Double(metrics.projectCount), min: 5, max: 26) +
            0.22 * rangeScore(metrics.activeDayCoverage, min: 0.25, max: 0.85) +
            0.16 * rangeScore(Double(metrics.activeDayCount), min: 12, max: 220) +
            0.12 * rangeScore(Double(metrics.toolCategoryCount), min: 3, max: 9) +
            0.10 * rangeScore(Double(metrics.modelCount), min: 2, max: 8) +
            0.06 * liftScore(metrics.projectCount, baseline?.projectCount)

        if metrics.projectCount < 5 {
            score = 0
        }
        if metrics.projectCount >= 10 && metrics.activeDayCount >= 20 {
            score += 0.06
        }
        if hasStrongToolSignature(metrics) || hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongSprintSignature(metrics) {
            score -= 0.10
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.10
        }
        return min(score, 1.2)
    }

    static func allTimeVibeCodingKingScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        longHorizonVibeCodingKingScore(metrics: metrics, baseline: baseline)
    }

    static func allTimeToolSummonerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateToolSignature(metrics) else { return 0 }
        var score =
            0.46 * rangeScore(metrics.toolUsePerMessage, min: 0.20, max: 0.75) +
            0.30 * rangeScore(Double(metrics.toolCategoryCount), min: 3, max: 9) +
            0.12 * rangeScore(Double(metrics.toolUseCount), min: 120, max: 1_800) +
            0.12 * liftScore(metrics.toolUsePerMessage, baseline?.toolUsePerMessage)
        if hasStrongToolSignature(metrics) {
            score += 0.10
        }
        if hasModerateToolSignature(metrics) {
            score += 0.03
        }
        if hasModerateContextSignature(metrics) || hasModerateMultiModelSignature(metrics) || hasModerateNightSignature(metrics) {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    static func allTimeContextBeastTamerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateContextSignature(metrics) else { return 0 }
        var score =
            0.30 * rangeScore(metrics.averageContextUsagePercent, min: 8, max: 30) +
            0.22 * rangeScore(Double(metrics.cacheReadTokens), min: 80_000, max: 3_000_000) +
            0.22 * rangeScore(metrics.longSessionRatio, min: 0.16, max: 0.6) +
            0.16 * rangeScore(cacheReadRatio(metrics), min: 0.04, max: 0.28) +
            0.06 * rangeScore(metrics.averageTokensPerSession, min: 30_000, max: 450_000) +
            0.04 * liftScore(metrics.averageContextUsagePercent, baseline?.averageContextUsagePercent)
        if hasStrongContextSignature(metrics) {
            score += 0.10
        }
        if hasModerateContextSignature(metrics) {
            score += 0.04
        }
        if hasModerateToolSignature(metrics) || hasModerateMultiModelSignature(metrics) {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    static func allTimeNightShiftEngineerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateNightSignature(metrics) else { return 0 }
        var score =
            0.45 * rangeScore(metrics.nightTokenRatio, min: 0.18, max: 0.8) +
            0.30 * rangeScore(metrics.nightSessionRatio, min: 0.18, max: 0.8) +
            0.25 * rangeScore(Double(metrics.nightSessionCount), min: 6, max: 80)
        score += 0.10 * liftScore(metrics.nightTokenRatio, baseline?.nightTokenRatio)
        if hasStrongNightSignature(metrics) {
            score += 0.14
        }
        if hasModerateNightSignature(metrics) {
            score += 0.08
        }
        return min(score, 1.2)
    }

    static func allTimeMultiModelDirectorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateMultiModelSignature(metrics) else { return 0 }
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        let baselineAdjustedModelCount = baseline.map(providerAdjustedModelCount)
        var score =
            0.12 * rangeScore(Double(metrics.providerCount), min: 1, max: 3) +
            0.42 * rangeScore(Double(adjustedModelCount), min: 2, max: 8) +
            0.30 * rangeScore(metrics.modelEntropy, min: 0.34, max: 0.95) +
            0.10 * liftScore(metrics.modelEntropy, baseline?.modelEntropy) +
            0.06 * liftScore(adjustedModelCount, baselineAdjustedModelCount)
        if hasStrongMultiModelSignature(metrics) {
            score += 0.14
        }
        if hasModerateMultiModelSignature(metrics) {
            score += 0.10
        }
        if metrics.providerCount >= 2 && adjustedModelCount < 3 {
            score -= 0.24
        }
        return min(score, 1.2)
    }

    static func allTimeSprintHackerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.peakFiveMinuteTokens >= 120_000 || metrics.singleDayPeakRatio >= 0.24 else { return 0 }
        var score =
            0.42 * rangeScore(metrics.singleDayPeakRatio, min: 0.18, max: 0.65) +
            0.34 * rangeScore(Double(metrics.peakFiveMinuteTokens), min: 120_000, max: 6_000_000) +
            0.24 * rangeScore(Double(metrics.peakDayTokens), min: 300_000, max: 20_000_000)
        score += 0.10 * liftScore(metrics.singleDayPeakRatio, baseline?.singleDayPeakRatio)
        if hasStrongSprintSignature(metrics) {
            score += 0.14
        }
        return min(score, 1.2)
    }

    static func allTimeFullStackPathfinderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        longHorizonFullStackPathfinderScore(metrics: metrics, baseline: baseline)
    }

    static func allTimeEfficientOperatorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.totalCost >= 4.0,
              metrics.totalTokens >= 1_000_000,
              metrics.sessionCount >= 12,
              metrics.estimatedCostRatio <= 0.78 else {
            return 0
        }
        var score =
            0.24 * rangeScore(metrics.tokensPerDollar, min: 110_000, max: 380_000) +
            0.16 * rangeScore(metrics.messagesPerDollar, min: 8, max: 48) +
            0.16 * inverseRangeScore(metrics.costPerSession, min: 3.0, max: 14) +
            0.24 * rangeScore(Double(metrics.totalTokens), min: 1_000_000, max: 12_000_000) +
            0.12 * rangeScore(Double(metrics.sessionCount), min: 12, max: 160) +
            0.08 * liftScore(metrics.tokensPerDollar, baseline?.tokensPerDollar)
        if hasStrongEfficiencySignature(metrics) {
            score += 0.10
        }
        if hasStrongToolSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.12
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.06
        }
        return min(score, 1.2)
    }

    static func allTimeSteadyBuilderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.36 * rangeScore(metrics.activeDayCoverage, min: 0.28, max: 0.95) +
            0.22 * rangeScore(Double(metrics.activeDayCount), min: 10, max: 240) +
            0.20 * rangeScore(Double(metrics.sessionCount), min: 10, max: 220) +
            0.12 * rangeScore(Double(metrics.messageCount), min: 120, max: 10_000) +
            0.10 * inverseRangeScore(metrics.singleDayPeakRatio, min: 0.08, max: 0.45)
        score += 0.06 * liftScore(metrics.activeDayCoverage, baseline?.activeDayCoverage)
        if hasStrongToolSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) || hasStrongSprintSignature(metrics) {
            score -= 0.12
        }
        return min(score, 1.2)
    }
}
