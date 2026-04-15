import Foundation

struct ShareMetricsBuilder {
    static func build(
        sessions: [Session],
        parsedStats: [String: SessionStats],
        providerKind: ProviderKind,
        period: PeriodStats,
        periodType: StatsPeriod,
        weeklyResetDate: Date?
    ) -> ShareMetrics? {
        let interval = periodInterval(for: period.period, periodType: periodType)
        return buildMetrics(
            sessions: sessions,
            parsedStats: parsedStats,
            providerKind: providerKind,
            providerKinds: [providerKind],
            scope: periodType,
            scopeLabel: period.periodLabel,
            period: interval
        ) { date in
            periodType.startOfPeriod(for: date, weeklyResetDate: weeklyResetDate) == period.period
        }
    }

    static func build(
        sessions: [Session],
        parsedStats: [String: SessionStats],
        providerKind: ProviderKind,
        scope: StatsPeriod,
        interval: DateInterval,
        scopeLabel: String? = nil
    ) -> ShareMetrics? {
        buildMetrics(
            sessions: sessions,
            parsedStats: parsedStats,
            providerKind: providerKind,
            providerKinds: [providerKind],
            scope: scope,
            scopeLabel: scopeLabel ?? rangeLabel(for: interval),
            period: interval
        ) { date in
            date >= interval.start && date < interval.end
        }
    }

    static func merge(
        _ metrics: [ShareMetrics],
        scope: StatsPeriod,
        scopeLabel: String,
        period: DateInterval
    ) -> ShareMetrics? {
        guard !metrics.isEmpty else { return nil }

        var providerKinds = Set<ProviderKind>()
        var providerSessionCounts: [ProviderKind: Int] = [:]
        var providerTokenCounts: [ProviderKind: Int] = [:]
        var toolUseCounts: [String: Int] = [:]
        var modelTokenBreakdown: [String: Int] = [:]

        var sessionCount = 0
        var messageCount = 0
        var totalTokens = 0
        var totalCost = 0.0
        var projectCount = 0
        var toolUseCount = 0
        var activeDayCount = 0
        var totalDayCount = 0
        var nightSessionCount = 0
        var nightTokenCount = 0
        var cacheReadTokens = 0
        var contextWeightedTotal = 0.0
        var contextWeight = 0
        var averageTokensWeightedTotal = 0.0
        var averageMessagesWeightedTotal = 0.0
        var longSessionCount = 0
        var peakDayTokens = 0
        var peakFiveMinuteTokens = 0
        var estimatedCostSessionCount = 0

        for item in metrics {
            providerKinds.formUnion(item.providerKinds)
            sessionCount += item.sessionCount
            messageCount += item.messageCount
            totalTokens += item.totalTokens
            totalCost += item.totalCost
            projectCount += item.projectCount
            toolUseCount += item.toolUseCount
            activeDayCount = max(activeDayCount, item.activeDayCount)
            totalDayCount = max(totalDayCount, item.totalDayCount)
            nightSessionCount += item.nightSessionCount
            nightTokenCount += item.nightTokenCount
            cacheReadTokens += item.cacheReadTokens
            contextWeightedTotal += item.averageContextUsagePercent * Double(item.sessionCount)
            contextWeight += item.sessionCount
            averageTokensWeightedTotal += item.averageTokensPerSession * Double(item.sessionCount)
            averageMessagesWeightedTotal += item.averageMessagesPerSession * Double(item.sessionCount)
            longSessionCount += item.longSessionCount
            peakDayTokens = max(peakDayTokens, item.peakDayTokens)
            peakFiveMinuteTokens = max(peakFiveMinuteTokens, item.peakFiveMinuteTokens)
            estimatedCostSessionCount += item.estimatedCostSessionCount

            for (provider, value) in item.providerSessionCounts {
                providerSessionCounts[provider, default: 0] += value
            }
            for (provider, value) in item.providerTokenCounts {
                providerTokenCounts[provider, default: 0] += value
            }
            for (tool, value) in item.toolUseCounts {
                toolUseCounts[tool, default: 0] += value
            }
            for (model, value) in item.modelTokenBreakdown {
                modelTokenBreakdown[model, default: 0] += value
            }
        }

        let averageContextUsage = contextWeight > 0 ? (contextWeightedTotal / Double(contextWeight)) : 0
        let averageTokensPerSession = sessionCount > 0 ? (averageTokensWeightedTotal / Double(sessionCount)) : 0
        let averageMessagesPerSession = sessionCount > 0 ? (averageMessagesWeightedTotal / Double(sessionCount)) : 0

        return ShareMetrics(
            scope: scope,
            scopeLabel: scopeLabel,
            period: period,
            providerKinds: providerKinds,
            providerSessionCounts: providerSessionCounts,
            providerTokenCounts: providerTokenCounts,
            sessionCount: sessionCount,
            messageCount: messageCount,
            totalTokens: totalTokens,
            totalCost: totalCost,
            projectCount: projectCount,
            toolUseCount: toolUseCount,
            toolCategoryCount: toolUseCounts.count,
            activeDayCount: activeDayCount,
            totalDayCount: max(1, totalDayCount),
            nightSessionCount: nightSessionCount,
            nightTokenCount: nightTokenCount,
            cacheReadTokens: cacheReadTokens,
            averageContextUsagePercent: averageContextUsage,
            averageTokensPerSession: averageTokensPerSession,
            averageMessagesPerSession: averageMessagesPerSession,
            longSessionCount: longSessionCount,
            modelCount: modelTokenBreakdown.count,
            modelEntropy: normalizedEntropy(for: modelTokenBreakdown),
            peakDayTokens: peakDayTokens,
            peakFiveMinuteTokens: peakFiveMinuteTokens,
            estimatedCostSessionCount: estimatedCostSessionCount,
            toolUseCounts: toolUseCounts,
            modelTokenBreakdown: modelTokenBreakdown
        )
    }

    static func periodInterval(for periodStart: Date, periodType: StatsPeriod) -> DateInterval {
        let cal = Calendar.current
        let end: Date
        switch periodType {
        case .daily:
            end = cal.date(byAdding: .day, value: 1, to: periodStart) ?? periodStart
        case .weekly:
            end = cal.date(byAdding: .day, value: 7, to: periodStart) ?? periodStart
        case .monthly:
            end = cal.date(byAdding: .month, value: 1, to: periodStart) ?? periodStart
        case .yearly:
            end = cal.date(byAdding: .year, value: 1, to: periodStart) ?? periodStart
        }
        return DateInterval(start: periodStart, end: end)
    }

    private static func buildMetrics(
        sessions: [Session],
        parsedStats: [String: SessionStats],
        providerKind: ProviderKind,
        providerKinds: Set<ProviderKind>,
        scope: StatsPeriod,
        scopeLabel: String,
        period: DateInterval,
        includeDate: (Date) -> Bool
    ) -> ShareMetrics? {
        let cal = Calendar.current
        var includedSessionIds = Set<String>()
        var uniqueProjects = Set<String>()
        var activeDays = Set<Date>()
        var nightSessionIds = Set<String>()
        var toolUseCounts: [String: Int] = [:]
        var modelTokenBreakdown: [String: Int] = [:]
        var dayTokenBuckets: [Date: Int] = [:]

        var totalTokens = 0
        var totalCost = 0.0
        var messageCount = 0
        var toolUseCount = 0
        var nightTokenCount = 0
        var cacheReadTokens = 0
        var contextPercentTotal = 0.0
        var contextPercentCount = 0
        var longSessionCount = 0
        var estimatedCostSessionCount = 0
        var peakFiveMinuteTokens = 0

        for session in sessions {
            guard let stats = parsedStats[session.id] else { continue }

            var sessionIncluded = false
            var sessionNight = false

            if !stats.fiveMinSlices.isEmpty {
                for (sliceTime, slice) in stats.fiveMinSlices {
                    guard includeDate(sliceTime) else { continue }
                    sessionIncluded = true
                    totalTokens += slice.totalTokens
                    totalCost += slice.estimatedCost
                    messageCount += slice.messageCount
                    toolUseCount += slice.toolUseTotal
                    cacheReadTokens += slice.cacheReadTokens
                    peakFiveMinuteTokens = max(peakFiveMinuteTokens, slice.totalTokens)

                    let dayStart = cal.startOfDay(for: sliceTime)
                    activeDays.insert(dayStart)
                    dayTokenBuckets[dayStart, default: 0] += slice.totalTokens

                    if isNightHour(sliceTime, calendar: cal) {
                        nightTokenCount += slice.totalTokens
                        sessionNight = true
                    }

                    for (tool, count) in slice.toolUseCounts {
                        toolUseCounts[tool, default: 0] += count
                    }
                    for (model, modelStats) in slice.modelBreakdown {
                        modelTokenBreakdown[model, default: 0] += modelStats.totalTokens
                    }
                }
            } else {
                let fallbackDate = stats.startTime ?? session.startTime ?? session.lastModified
                guard includeDate(fallbackDate) else { continue }
                sessionIncluded = true
                totalTokens += stats.totalTokens
                totalCost += stats.estimatedCost
                messageCount += stats.messageCount
                toolUseCount += stats.toolUseTotal
                cacheReadTokens += stats.cacheReadTokens
                peakFiveMinuteTokens = max(peakFiveMinuteTokens, stats.totalTokens)

                let dayStart = cal.startOfDay(for: fallbackDate)
                activeDays.insert(dayStart)
                dayTokenBuckets[dayStart, default: 0] += stats.totalTokens

                if isNightHour(fallbackDate, calendar: cal) {
                    nightTokenCount += stats.totalTokens
                    sessionNight = true
                }

                for (tool, count) in stats.toolUseCounts {
                    toolUseCounts[tool, default: 0] += count
                }
                for (model, modelStats) in stats.modelBreakdown {
                    modelTokenBreakdown[model, default: 0] += modelStats.totalTokens
                }
                if stats.modelBreakdown.isEmpty {
                    modelTokenBreakdown[stats.model, default: 0] += stats.totalTokens
                }
            }

            guard sessionIncluded else { continue }

            includedSessionIds.insert(session.id)
            uniqueProjects.insert(session.cwd ?? session.projectPath)

            if stats.contextUsagePercent > 0 {
                contextPercentTotal += stats.contextUsagePercent
                contextPercentCount += 1
            }
            if let duration = stats.duration, duration >= 3600 {
                longSessionCount += 1
            }
            if stats.isCostEstimated {
                estimatedCostSessionCount += 1
            }
            if sessionNight {
                nightSessionIds.insert(session.id)
            }
        }

        guard !includedSessionIds.isEmpty else { return nil }

        let totalDayCount = max(1, cal.dateComponents([.day], from: cal.startOfDay(for: period.start), to: cal.startOfDay(for: period.end)).day ?? 0)
        let averageContextUsage = contextPercentCount > 0 ? (contextPercentTotal / Double(contextPercentCount)) : 0
        let averageTokensPerSession = Double(totalTokens) / Double(includedSessionIds.count)
        let averageMessagesPerSession = Double(messageCount) / Double(includedSessionIds.count)
        let peakDayTokens = dayTokenBuckets.values.max() ?? totalTokens
        let modelCount = modelTokenBreakdown.count

        return ShareMetrics(
            scope: scope,
            scopeLabel: scopeLabel,
            period: period,
            providerKinds: providerKinds,
            providerSessionCounts: [providerKind: includedSessionIds.count],
            providerTokenCounts: [providerKind: totalTokens],
            sessionCount: includedSessionIds.count,
            messageCount: messageCount,
            totalTokens: totalTokens,
            totalCost: totalCost,
            projectCount: uniqueProjects.count,
            toolUseCount: toolUseCount,
            toolCategoryCount: toolUseCounts.count,
            activeDayCount: activeDays.count,
            totalDayCount: totalDayCount,
            nightSessionCount: nightSessionIds.count,
            nightTokenCount: nightTokenCount,
            cacheReadTokens: cacheReadTokens,
            averageContextUsagePercent: averageContextUsage,
            averageTokensPerSession: averageTokensPerSession,
            averageMessagesPerSession: averageMessagesPerSession,
            longSessionCount: longSessionCount,
            modelCount: modelCount,
            modelEntropy: normalizedEntropy(for: modelTokenBreakdown),
            peakDayTokens: peakDayTokens,
            peakFiveMinuteTokens: peakFiveMinuteTokens,
            estimatedCostSessionCount: estimatedCostSessionCount,
            toolUseCounts: toolUseCounts,
            modelTokenBreakdown: modelTokenBreakdown
        )
    }

    private static func normalizedEntropy(for buckets: [String: Int]) -> Double {
        let total = buckets.values.reduce(0, +)
        guard total > 0, buckets.count > 1 else { return 0 }

        let entropy = buckets.values.reduce(0.0) { partial, count in
            let p = Double(count) / Double(total)
            guard p > 0 else { return partial }
            return partial - (p * log2(p))
        }
        let maxEntropy = log2(Double(buckets.count))
        guard maxEntropy > 0 else { return 0 }
        return entropy / maxEntropy
    }

    private static func isNightHour(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 4
    }

    private static func rangeLabel(for interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return "\(formatter.string(from: interval.start))-\(formatter.string(from: interval.end))"
    }
}
