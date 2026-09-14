import Foundation
import ClaudeStatisticsKit

/// Pure trend / window / model-breakdown folds over `parsedStats`. These were
/// `nonisolated static` helpers on `SessionDataStore`; pulling them out keeps
/// the store focused on UI state while letting view-models and tests reuse the
/// algorithms directly.
///
/// The store still exposes thin `aggregate*` wrappers that snapshot
/// main-actor state and dispatch to these via `Task.detached` for the heavy
/// folds.
enum SessionTrendAggregator {

    static func trendData(
        parsedStats: [String: SessionStats],
        sessions: [Session],
        period: PeriodStats,
        periodType: StatsPeriod,
        weeklyResetDate: Date?
    ) -> [TrendDataPoint] {
        let granularity = periodType.trendGranularity
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        // Use fiveMinSlices for daily view or weekly with non-midnight subscription boundary
        let useFineSlices = periodType == .daily || (periodType == .weekly && weeklyResetDate != nil)

        let sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        for (sessionId, stats) in parsedStats {
            let slices: [Date: DaySlice] = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            if !slices.isEmpty {
                for (sliceTime, slice) in slices {
                    let slicePeriodStart = periodType.startOfPeriod(for: sliceTime, weeklyResetDate: weeklyResetDate)
                    guard slicePeriodStart == period.period else { continue }

                    let bucket = granularity.bucketStart(for: sliceTime)
                    var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
                    existing.tokens += slice.totalTokens
                    existing.cost += slice.estimatedCost
                    buckets[bucket] = existing
                }
            } else {
                // Fallback for sessions without hourSlice data
                guard let session = sessionById[sessionId] else { continue }
                let sessionDate = stats.startTime ?? session.lastModified
                let sessionPeriodStart = periodType.startOfPeriod(for: sessionDate, weeklyResetDate: weeklyResetDate)
                guard sessionPeriodStart == period.period else { continue }

                let bucket = granularity.bucketStart(for: sessionDate)
                var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
                existing.tokens += stats.totalTokens
                existing.cost += stats.estimatedCost
                buckets[bucket] = existing
            }
        }

        // Sort by time, then accumulate into running totals
        let sorted = buckets.sorted { $0.key < $1.key }
        let cal = Calendar.current
        var result: [TrendDataPoint] = []

        // Zero-origin baseline. For bounded periods (daily/weekly/monthly), `period.period`
        // is the exact start-of-period. For `.all`, `period.period` is `distantPast` which
        // would blow up the X-axis, so pin the baseline to the first bucket instead.
        if !sorted.isEmpty {
            let origin: Date = (periodType == .all) ? sorted.first!.key : period.period
            result.append(TrendDataPoint(time: origin, tokens: 0, cost: 0))
        }

        // Data points at the END of each bucket (cumulative up to that point)
        var cumTokens = 0
        var cumCost = 0.0
        for (i, (time, val)) in sorted.enumerated() {
            cumTokens += val.tokens
            cumCost += val.cost
            // End of bucket = start of next granularity unit
            // For the last bucket, cap at "now" to avoid showing future time
            let bucketEnd = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: time)!
            let dataTime = (i == sorted.count - 1) ? min(bucketEnd, Date()) : bucketEnd
            result.append(TrendDataPoint(time: dataTime, tokens: cumTokens, cost: cumCost))
        }
        return result
    }

    /// Aggregate raw token/cost usage for a rolling time window.
    static func windowTrendData(
        parsedStats: [String: SessionStats],
        from start: Date,
        to end: Date,
        granularity: TrendGranularity,
        cumulative: Bool = false,
        modelFilter: ((String) -> Bool)? = nil,
        pricing: ModelPricing.Snapshot = ModelPricing.shared.snapshot(),
        maxPoints: Int? = nil
    ) -> [TrendDataPoint] {
        guard start < end else { return [] }

        let cal = Calendar.current
        let useFineSlices = granularity == .fiveMinute || granularity == .minute || granularity == .hour
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        for stats in parsedStats.values {
            if Task.isCancelled { return [] }
            let slices: [Date: DaySlice] = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            for (sliceTime, slice) in slices {
                if Task.isCancelled { return [] }
                // Exclusive start: data at exact boundary belongs to previous period
                guard sliceTime > start, sliceTime < end else { continue }

                let bucket = granularity.bucketStart(for: sliceTime)
                var existing = buckets[bucket, default: (tokens: 0, cost: 0)]

                if let filter = modelFilter {
                    for (model, modelStats) in slice.modelBreakdown where filter(model) {
                        existing.tokens += modelStats.totalTokens
                        existing.cost += pricing.estimateCost(model: model, tokens: modelStats)
                    }
                } else {
                    existing.tokens += slice.totalTokens
                    existing.cost += pricing.estimateCost(slice: slice)
                }
                buckets[bucket] = existing
            }
        }

        if cumulative {
            var result: [TrendDataPoint] = [TrendDataPoint(time: start, tokens: 0, cost: 0)]
            var bucketTime = granularity.bucketStart(for: start)
            var cumTokens = 0
            var cumCost = 0.0
            // Only bound the rendered cumulative samples. Every source bucket
            // still contributes and the exact start/end totals are preserved.
            let steps = max(0, cal.dateComponents([granularity.calendarComponent], from: bucketTime, to: end)
                .value(for: granularity.calendarComponent) ?? 0) / granularity.stepValue + 1
            let interiorLimit = max(1, (maxPoints ?? (steps + 2)) - 2)
            let stride = max(1, (steps + interiorLimit - 1) / interiorLimit)
            var index = 0

            while bucketTime < end {
                if Task.isCancelled { return [] }
                let bucket = buckets[bucketTime, default: (tokens: 0, cost: 0)]
                cumTokens += bucket.tokens
                cumCost += bucket.cost
                // Only add points after the zero-origin to keep x-axis monotonic
                if bucketTime > start && index % stride == 0 {
                    result.append(TrendDataPoint(time: bucketTime, tokens: cumTokens, cost: cumCost))
                }
                guard let nextBucket = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: bucketTime) else { break }
                bucketTime = nextBucket
                index += 1
            }

            // Data from the first or current partial bucket was accumulated but not yet plotted
            // if the loop ended before the next boundary. Append it at the exact end time.
            if result.last?.time != end {
                result.append(TrendDataPoint(time: end, tokens: cumTokens, cost: cumCost))
            }

            return result
        }

        // Non-cumulative: per-bucket values
        var result: [TrendDataPoint] = []
        var bucketTime = granularity.bucketStart(for: start)

        while bucketTime < end {
            if Task.isCancelled { return [] }
            let bucket = buckets[bucketTime, default: (tokens: 0, cost: 0)]
            result.append(TrendDataPoint(time: bucketTime, tokens: bucket.tokens, cost: bucket.cost))
            guard let nextBucket = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: bucketTime) else { break }
            bucketTime = nextBucket
        }

        return result
    }

    static func projectTrend(stats: [SessionStats], granularity: TrendGranularity) -> [TrendDataPoint] {
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]
        let cal = Calendar.current

        for stat in stats {
            for (time, slice) in stat.fiveMinSlices {
                let bucket = granularity.bucketStart(for: time)
                var existing = buckets[bucket, default: (tokens: 0, cost: 0.0)]
                existing.tokens += slice.totalTokens
                existing.cost += slice.estimatedCost
                buckets[bucket] = existing
            }
        }

        let sorted = buckets.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return [] }

        var result: [TrendDataPoint] = [TrendDataPoint(time: sorted.first!.key, tokens: 0, cost: 0)]
        var cumTokens = 0
        var cumCost = 0.0
        for (i, (time, val)) in sorted.enumerated() {
            cumTokens += val.tokens
            cumCost += val.cost
            let bucketEnd = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: time)!
            let dataTime = (i == sorted.count - 1) ? min(bucketEnd, Date()) : bucketEnd
            result.append(TrendDataPoint(time: dataTime, tokens: cumTokens, cost: cumCost))
        }
        return result
    }

    static func projectModelBreakdown(stats: [SessionStats]) -> [ModelUsage] {
        var combined: [String: ModelUsage] = [:]
        for st in stats {
            for (model, mts) in st.modelBreakdown {
                var usage = combined[model] ?? ModelUsage(model: model)
                usage.inputTokens += mts.inputTokens
                usage.outputTokens += mts.outputTokens
                usage.cacheCreation5mTokens += mts.cacheCreation5mTokens
                usage.cacheCreation1hTokens += mts.cacheCreation1hTokens
                usage.cacheCreationTotalTokens += mts.cacheCreationTotalTokens
                usage.cacheReadTokens += mts.cacheReadTokens
                usage.cost += ModelPricing.estimateCost(
                    model: model,
                    inputTokens: mts.inputTokens,
                    outputTokens: mts.outputTokens,
                    cacheCreation5mTokens: mts.cacheCreation5mTokens,
                    cacheCreation1hTokens: mts.cacheCreation1hTokens,
                    cacheCreationTotalTokens: mts.cacheCreationTotalTokens,
                    cacheReadTokens: mts.cacheReadTokens
                )
                usage.messageCount += mts.messageCount
                usage.sessionCount += 1
                combined[model] = usage
            }
        }
        return combined.values.sorted { $0.cost > $1.cost }
    }

    static func windowModelBreakdown(
        parsedStats: [String: SessionStats],
        from start: Date,
        to end: Date,
        modelFilter: ((String) -> Bool)? = nil,
        pricing: ModelPricing.Snapshot = ModelPricing.shared.snapshot()
    ) -> [ModelUsage] {
        guard start < end else { return [] }

        var combined: [String: ModelUsage] = [:]
        var modelSessionIds: [String: Set<String>] = [:]

        for (sessionId, stats) in parsedStats {
            if Task.isCancelled { return [] }
            for (sliceTime, slice) in stats.fiveMinSlices {
                if Task.isCancelled { return [] }
                // Exclusive start: data at exact boundary belongs to previous period
                guard sliceTime > start, sliceTime < end else { continue }

                for (model, modelStats) in slice.modelBreakdown {
                    if let filter = modelFilter, !filter(model) { continue }
                    var existing = combined[model] ?? ModelUsage(model: model)
                    existing.inputTokens += modelStats.inputTokens
                    existing.outputTokens += modelStats.outputTokens
                    existing.cacheCreation5mTokens += modelStats.cacheCreation5mTokens
                    existing.cacheCreation1hTokens += modelStats.cacheCreation1hTokens
                    existing.cacheCreationTotalTokens += modelStats.cacheCreationTotalTokens
                    existing.cacheReadTokens += modelStats.cacheReadTokens
                    existing.cost += pricing.estimateCost(model: model, tokens: modelStats)
                    existing.messageCount += modelStats.messageCount
                    combined[model] = existing
                    modelSessionIds[model, default: []].insert(sessionId)
                }
            }
        }

        for (model, ids) in modelSessionIds {
            if var usage = combined[model] {
                usage.sessionCount = ids.count
                combined[model] = usage
            }
        }

        return combined.values.sorted { $0.totalTokens > $1.totalTokens }
    }
}
