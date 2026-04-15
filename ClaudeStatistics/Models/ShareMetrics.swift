import Foundation

struct ShareMetrics {
    let scope: StatsPeriod
    let scopeLabel: String
    let period: DateInterval
    let providerKinds: Set<ProviderKind>
    let providerSessionCounts: [ProviderKind: Int]
    let providerTokenCounts: [ProviderKind: Int]
    let sessionCount: Int
    let messageCount: Int
    let totalTokens: Int
    let totalCost: Double
    let projectCount: Int
    let toolUseCount: Int
    let toolCategoryCount: Int
    let activeDayCount: Int
    let totalDayCount: Int
    let nightSessionCount: Int
    let nightTokenCount: Int
    let cacheReadTokens: Int
    let averageContextUsagePercent: Double
    let averageTokensPerSession: Double
    let averageMessagesPerSession: Double
    let longSessionCount: Int
    let modelCount: Int
    let modelEntropy: Double
    let peakDayTokens: Int
    let peakFiveMinuteTokens: Int
    let estimatedCostSessionCount: Int
    let toolUseCounts: [String: Int]
    let modelTokenBreakdown: [String: Int]

    var activityVolumeScore: Double {
        let sessionSignal = min(Double(sessionCount) / 12.0, 1.0)
        let tokenSignal = min(Double(totalTokens) / 300_000.0, 1.0)
        let messageSignal = min(Double(messageCount) / 120.0, 1.0)
        return (sessionSignal * 0.35) + (tokenSignal * 0.4) + (messageSignal * 0.25)
    }

    var toolUsePerMessage: Double {
        guard messageCount > 0 else { return 0 }
        return Double(toolUseCount) / Double(messageCount)
    }

    var activeDayCoverage: Double {
        guard totalDayCount > 0 else { return 0 }
        return Double(activeDayCount) / Double(totalDayCount)
    }

    var nightTokenRatio: Double {
        guard totalTokens > 0 else { return 0 }
        return Double(nightTokenCount) / Double(totalTokens)
    }

    var nightSessionRatio: Double {
        guard sessionCount > 0 else { return 0 }
        return Double(nightSessionCount) / Double(sessionCount)
    }

    var longSessionRatio: Double {
        guard sessionCount > 0 else { return 0 }
        return Double(longSessionCount) / Double(sessionCount)
    }

    var tokensPerDollar: Double {
        guard totalCost > 0 else { return Double(totalTokens) }
        return Double(totalTokens) / totalCost
    }

    var messagesPerDollar: Double {
        guard totalCost > 0 else { return Double(messageCount) }
        return Double(messageCount) / totalCost
    }

    var costPerSession: Double {
        guard sessionCount > 0 else { return totalCost }
        return totalCost / Double(sessionCount)
    }

    var singleDayPeakRatio: Double {
        guard totalTokens > 0 else { return 0 }
        return Double(peakDayTokens) / Double(totalTokens)
    }

    var estimatedCostRatio: Double {
        guard sessionCount > 0 else { return 1 }
        return Double(estimatedCostSessionCount) / Double(sessionCount)
    }

    var providerCount: Int {
        providerKinds.count
    }

    var dominantProvider: ProviderKind? {
        providerTokenCounts.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue < rhs.key.rawValue
            }
            return lhs.value < rhs.value
        }?.key
    }

    func modelShare(containing needle: String) -> Double {
        let total = modelTokenBreakdown.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let matched = modelTokenBreakdown.reduce(0) { partial, entry in
            partial + (entry.key.localizedCaseInsensitiveContains(needle) ? entry.value : 0)
        }
        return Double(matched) / Double(total)
    }
}
