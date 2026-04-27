import ClaudeStatisticsKit
import Foundation

/// Bridge from the host's private `ShareMetrics` aggregate into the
/// SDK-side `ShareRoleEvaluationContext` that `ShareRolePlugin`
/// implementations consume. Splits provider-keyed dictionaries into
/// `descriptor.id` strings so plugins never have to know about the
/// host's `ProviderKind` type.
extension ShareMetrics {
    func evaluationContext(baseline: ShareMetrics?) -> ShareRoleEvaluationContext {
        ShareRoleEvaluationContext(
            scope: scope.rawValue,
            scopeLabel: scopeLabel,
            sessionCount: sessionCount,
            messageCount: messageCount,
            totalTokens: totalTokens,
            totalCost: totalCost,
            projectCount: projectCount,
            toolUseCount: toolUseCount,
            toolCategoryCount: toolCategoryCount,
            activeDayCount: activeDayCount,
            totalDayCount: totalDayCount,
            nightSessionCount: nightSessionCount,
            nightTokenCount: nightTokenCount,
            cacheReadTokens: cacheReadTokens,
            averageContextUsagePercent: averageContextUsagePercent,
            averageTokensPerSession: averageTokensPerSession,
            averageMessagesPerSession: averageMessagesPerSession,
            longSessionCount: longSessionCount,
            modelCount: modelCount,
            modelEntropy: modelEntropy,
            peakDayTokens: peakDayTokens,
            peakFiveMinuteTokens: peakFiveMinuteTokens,
            estimatedCostSessionCount: estimatedCostSessionCount,
            providerCount: providerCount,
            dominantProviderID: dominantProvider?.rawValue,
            providerSessionCounts: providerSessionCounts.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            providerTokenCounts: providerTokenCounts.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            toolUseCounts: toolUseCounts,
            modelTokenBreakdown: modelTokenBreakdown,
            baseline: baseline.map { base in
                ShareRoleEvaluationContext.Baseline(
                    sessionCount: base.sessionCount,
                    messageCount: base.messageCount,
                    totalTokens: base.totalTokens,
                    totalCost: base.totalCost,
                    toolUseCount: base.toolUseCount,
                    activeDayCount: base.activeDayCount,
                    nightTokenCount: base.nightTokenCount
                )
            }
        )
    }
}
