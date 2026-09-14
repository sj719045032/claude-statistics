import Foundation
import ClaudeStatisticsKit

/// Retains compact per-session contributions, not raw transcripts or 5-minute
/// history. A revision touches only that session's old/new days and periods.
/// Raw integer totals are retractable; prices are applied from one immutable
/// snapshot at output time, so repricing never revisits historical slices.
actor IncrementalSessionAggregator {
    struct Input: Sendable {
        let stats: [String: SessionStats]
        let revisions: [String: UInt64]
        let sessions: [Session]
        let period: StatsPeriod
        let weeklyResetDate: Date?
        let allTimeLabel: String
        let pricing: ModelPricing.Snapshot
        let calendar: Calendar
    }

    struct Output: Sendable {
        let periods: [PeriodStats]
        let allTime: PeriodStats
        let heatmap: [Date: DailyHeatmapBucket]
        let years: [Int]
        let projects: [TopProject]
        let updatedSessions: Int
        let visitedSlices: Int
    }

    private struct Configuration: Equatable {
        let period: StatsPeriod
        let reset: Date?
        let calendar: Calendar
    }

    private struct Identity: Equatable {
        let project: String?
        let fallbackDate: Date
    }

    private struct Contribution {
        let revision: UInt64
        let identity: Identity
        var periods: [Date: DaySlice] = [:]
        var days: [Date: DaySlice] = [:]
        var all = DaySlice()
        var models: Set<String> = []
    }

    private struct Bucket {
        var tokens = DaySlice()
        var sessions = 0
        var modelSessions: [String: Int] = [:]

        mutating func adjust(_ value: DaySlice, models: Set<String>, adding: Bool) {
            if adding { tokens.merge(value) } else { tokens.subtract(value) }
            let sign = adding ? 1 : -1
            sessions += sign
            for model in models {
                modelSessions[model, default: 0] += sign
                if modelSessions[model] == 0 { modelSessions[model] = nil }
            }
        }

        func period(at date: Date, type: StatsPeriod, reset: Date?, allLabel: String,
                    pricing: ModelPricing.Snapshot) -> PeriodStats {
            var result = PeriodStats(period: date,
                                     periodLabel: type == .all ? allLabel : type.label(for: date, weeklyResetDate: reset),
                                     chartLabel: type == .all ? allLabel : type.chartLabel(for: date, weeklyResetDate: reset))
            result.totalInputTokens = tokens.totalInputTokens
            result.totalOutputTokens = tokens.totalOutputTokens
            result.cacheCreation5mTokens = tokens.cacheCreation5mTokens
            result.cacheCreation1hTokens = tokens.cacheCreation1hTokens
            result.cacheCreationTotalTokens = tokens.cacheCreationTotalTokens
            result.cacheReadTokens = tokens.cacheReadTokens
            result.totalCost = pricing.estimateCost(slice: tokens)
            result.sessionCount = sessions
            result.messageCount = tokens.messageCount
            result.toolUseCounts = tokens.toolUseCounts
            result.toolUseCount = tokens.toolUseTotal
            for (model, count) in modelSessions {
                let usage = tokens.modelBreakdown[model, default: ModelTokenStats()]
                let estimated = !pricing.isExactMatch(for: model)
                result.hasEstimatedCost = result.hasEstimatedCost || estimated
                result.modelBreakdown[model] = ModelUsage(
                    model: model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                    cacheCreation5mTokens: usage.cacheCreation5mTokens, cacheCreation1hTokens: usage.cacheCreation1hTokens,
                    cacheCreationTotalTokens: usage.cacheCreationTotalTokens, cacheReadTokens: usage.cacheReadTokens,
                    cost: pricing.estimateCost(model: model, tokens: usage), sessionCount: count,
                    messageCount: usage.messageCount, isEstimated: estimated)
            }
            return result
        }
    }

    private var configuration: Configuration?
    private var contributions: [String: Contribution] = [:]
    private var periods: [Date: Bucket] = [:]
    private var days: [Date: Bucket] = [:]
    private var projects: [String: Bucket] = [:]
    private var all = Bucket()

    func update(_ input: Input) throws -> Output {
        let next = Configuration(period: input.period, reset: input.weeklyResetDate, calendar: input.calendar)
        if configuration != next {
            contributions.removeAll()
            periods.removeAll()
            days.removeAll()
            projects.removeAll()
            all = Bucket()
            configuration = next
        }
        var updated = 0
        var visited = 0
        let sessionByID = Dictionary(uniqueKeysWithValues: input.sessions.map { ($0.id, $0) })
        for id in Set(contributions.keys).subtracting(input.stats.keys) {
            try Task.checkCancellation()
            let old = contributions.removeValue(forKey: id)!
            adjust(old, adding: false)
            updated += 1
        }
        for (id, stats) in input.stats {
            try Task.checkCancellation()
            let session = sessionByID[id]
            let identity = Identity(project: session.map { $0.cwd ?? $0.projectPath },
                                    fallbackDate: stats.startTime ?? session?.lastModified ?? .distantPast)
            let revision = input.revisions[id, default: 0]
            if let old = contributions[id], old.revision == revision, old.identity == identity { continue }
            var value = Contribution(revision: revision, identity: identity)
            // Build the replacement before retracting anything. Cancellation
            // cannot leave a partially removed contribution in this actor.
            for (time, slice) in stats.fiveMinSlices {
                try Task.checkCancellation()
                visited += 1
                value.all.merge(slice)
                value.days[input.calendar.startOfDay(for: time), default: DaySlice()].merge(slice)
                let key = input.period.startOfPeriod(for: time, weeklyResetDate: input.weeklyResetDate, calendar: input.calendar)
                value.periods[key, default: DaySlice()].merge(slice)
                value.models.formUnion(slice.modelBreakdown.keys)
            }
            if stats.fiveMinSlices.isEmpty {
                // Preserve a zero-usage session/model row without pretending
                // it has heatmap activity or a synthetic timestamped message.
                value.models = [stats.model]
                let key = input.period.startOfPeriod(for: identity.fallbackDate, weeklyResetDate: input.weeklyResetDate, calendar: input.calendar)
                value.periods[key] = DaySlice()
            }
            if let old = contributions[id] { adjust(old, adding: false) }
            adjust(value, adding: true)
            contributions[id] = value
            updated += 1
        }
        try Task.checkCancellation()
        let allTime = all.period(at: .distantPast, type: .all, reset: nil, allLabel: input.allTimeLabel, pricing: input.pricing)
        let rows = input.period == .all ? [allTime] : periods.map { date, bucket in
            bucket.period(at: date, type: input.period, reset: input.weeklyResetDate,
                          allLabel: input.allTimeLabel, pricing: input.pricing)
        }.sorted { $0.period > $1.period }
        let heatmap = Dictionary(uniqueKeysWithValues: days.map { date, bucket in
            (date, DailyHeatmapBucket(date: date, cost: input.pricing.estimateCost(slice: bucket.tokens), tokens: bucket.tokens.totalTokens))
        })
        var projectRows: [TopProject] = []
        for (path, bucket) in projects {
            projectRows.append(TopProject(path: path, displayName: SessionAllTimeAggregator.displayName(forProjectPath: path),
                                          cost: input.pricing.estimateCost(slice: bucket.tokens), tokens: bucket.tokens.totalTokens,
                                          sessionCount: bucket.sessions, messageCount: bucket.tokens.messageCount))
        }
        projectRows.sort { $0.cost == $1.cost ? $0.path < $1.path : $0.cost > $1.cost }
        return Output(periods: rows, allTime: allTime, heatmap: heatmap,
                      years: Set(days.keys.map { input.calendar.component(.year, from: $0) }).sorted(by: >),
                      projects: projectRows, updatedSessions: updated, visitedSlices: visited)
    }

    private func adjust(_ value: Contribution, adding: Bool) {
        all.adjust(value.all, models: value.models, adding: adding)
        for (date, slice) in value.periods {
            let models = value.all.isEmpty && value.days.isEmpty ? value.models : Set(slice.modelBreakdown.keys)
            periods[date, default: Bucket()].adjust(slice, models: models, adding: adding)
            if periods[date]?.sessions == 0 { periods[date] = nil }
        }
        for (date, slice) in value.days {
            days[date, default: Bucket()].adjust(slice, models: [], adding: adding)
            if days[date]?.sessions == 0 { days[date] = nil }
        }
        if let path = value.identity.project {
            projects[path, default: Bucket()].adjust(value.all, models: [], adding: adding)
            if projects[path]?.sessions == 0 { projects[path] = nil }
        }
    }
}
