import Foundation
import ClaudeStatisticsKit

/// Aggregated view of *all* parsed sessions used by the All-Time UI: per-day
/// heatmap buckets, the calendar years that contain data, and the per-cwd
/// "top projects" rollup. Computed in a single pass over `parsedStats` so the
/// heatmap and top-projects panels share one O(sessions × slices) walk.
struct AllTimeAggregates {
    var dailyHeatmap: [Date: DailyHeatmapBucket]
    var availableYears: [Int]
    var topProjects: [TopProject]
}

/// Pure folds for All-Time / per-period project rollups. These were
/// `nonisolated static` helpers on `SessionDataStore`; pulling them out makes
/// the store responsible for state mutation only and lets the algorithms be
/// covered directly in tests.
enum SessionAllTimeAggregator {

    /// Per-period rollup of project usage (key = `cwd ?? projectPath`).
    static func periodTopProjects(
        parsedStats: [String: SessionStats],
        sessions: [Session],
        period: PeriodStats,
        periodType: StatsPeriod,
        weeklyResetDate: Date?
    ) -> [TopProject] {
        struct Acc {
            var cost: Double = 0
            var tokens: Int = 0
            var sessionCount: Int = 0
            var messageCount: Int = 0
        }
        var acc: [String: Acc] = [:]
        let sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        let periodStart = period.period
        let periodEnd = periodType == .all ? Date.distantFuture : periodType.nextPeriodStart(after: periodStart, weeklyResetDate: weeklyResetDate)

        for (sessionId, stats) in parsedStats {
            guard let session = sessionById[sessionId] else { continue }
            let key = session.cwd ?? session.projectPath

            let sStart = stats.startTime ?? session.lastModified
            let sEnd = stats.endTime ?? session.lastModified

            // Check if session interval [sStart, sEnd] overlaps with [periodStart, periodEnd)
            let overlaps = sStart < periodEnd && sEnd >= periodStart
            guard overlaps else { continue }

            var a = acc[key, default: Acc()]

            if stats.fiveMinSlices.isEmpty {
                // For all-time aggregated stats (Date.distantPast), or if start periods match
                if periodType == .all || periodType.startOfPeriod(for: sStart, weeklyResetDate: weeklyResetDate) == periodStart {
                    a.cost += stats.estimatedCost
                    a.tokens += stats.totalTokens
                    a.messageCount += stats.messageCount
                    a.sessionCount += 1
                }
            } else {
                var costInPeriod = 0.0
                var tokensInPeriod = 0
                var messagesInPeriod = 0
                var hasActivityInPeriod = false

                for (sliceTime, slice) in stats.fiveMinSlices {
                    if sliceTime >= periodStart && sliceTime < periodEnd {
                        costInPeriod += slice.estimatedCost
                        tokensInPeriod += slice.totalTokens
                        messagesInPeriod += slice.messageCount
                        hasActivityInPeriod = true
                    }
                }

                if hasActivityInPeriod {
                    a.cost += costInPeriod
                    a.tokens += tokensInPeriod
                    a.messageCount += messagesInPeriod
                    a.sessionCount += 1
                } else if periodType == .all {
                    // Fallback for .all when slices exist but for some reason aren't matching
                    a.cost += stats.estimatedCost
                    a.tokens += stats.totalTokens
                    a.messageCount += stats.messageCount
                    a.sessionCount += 1
                }
            }
            acc[key] = a
        }

        return acc.map { key, v in
            TopProject(
                path: key,
                displayName: displayName(forProjectPath: key),
                cost: v.cost,
                tokens: v.tokens,
                sessionCount: v.sessionCount,
                messageCount: v.messageCount
            )
        }.filter { $0.sessionCount > 0 }.sorted { $0.cost > $1.cost }
    }

    /// Single-pass build of the All-Time heatmap, the years that contain data,
    /// and the per-cwd top-projects rollup. The heatmap's daily buckets are
    /// derived in the same loop as the top-projects per-cwd accumulator, so we
    /// avoid two passes over `parsedStats`.
    static func allTimeAggregates(
        parsedStats: [String: SessionStats],
        sessions: [Session]
    ) -> AllTimeAggregates {
        let cal = Calendar.current
        var heatmap: [Date: DailyHeatmapBucket] = [:]

        struct ProjectAcc {
            var cost: Double = 0
            var tokens: Int = 0
            var sessionCount: Int = 0
            var messageCount: Int = 0
        }
        var projectAcc: [String: ProjectAcc] = [:]
        let sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        for (sessionId, stats) in parsedStats {
            // Heatmap bucket
            for (sliceTime, slice) in stats.fiveMinSlices {
                let day = cal.startOfDay(for: sliceTime)
                var b = heatmap[day, default: DailyHeatmapBucket(date: day, cost: 0, tokens: 0)]
                b.cost += slice.estimatedCost
                b.tokens += slice.totalTokens
                heatmap[day] = b
            }

            // Top-projects accumulator
            guard let session = sessionById[sessionId] else { continue }
            let key = session.cwd ?? session.projectPath
            var a = projectAcc[key, default: ProjectAcc()]
            if stats.fiveMinSlices.isEmpty {
                a.cost += stats.estimatedCost
                a.tokens += stats.totalTokens
                a.messageCount += stats.messageCount
                a.sessionCount += 1
            } else {
                var costInPeriod = 0.0
                var tokensInPeriod = 0
                var messagesInPeriod = 0
                for (_, slice) in stats.fiveMinSlices {
                    costInPeriod += slice.estimatedCost
                    tokensInPeriod += slice.totalTokens
                    messagesInPeriod += slice.messageCount
                }
                a.cost += costInPeriod
                a.tokens += tokensInPeriod
                a.messageCount += messagesInPeriod
                a.sessionCount += 1
            }
            projectAcc[key] = a
        }

        let years = Set(heatmap.keys.map { cal.component(.year, from: $0) }).sorted(by: >)
        let topProjects = projectAcc.map { key, v in
            TopProject(
                path: key,
                displayName: displayName(forProjectPath: key),
                cost: v.cost,
                tokens: v.tokens,
                sessionCount: v.sessionCount,
                messageCount: v.messageCount
            )
        }.filter { $0.sessionCount > 0 }.sorted { $0.cost > $1.cost }

        return AllTimeAggregates(dailyHeatmap: heatmap, availableYears: years, topProjects: topProjects)
    }

    /// Trim/relabel a full path into something compact enough for a list row.
    /// Prefers the last path component (like the basename of a repo).
    static func displayName(forProjectPath path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let last = (expanded as NSString).lastPathComponent
        return last.isEmpty ? expanded : last
    }
}

// MARK: - All-Time helper types

struct TopProject: Identifiable, Hashable {
    let path: String
    let displayName: String
    let cost: Double
    let tokens: Int
    let sessionCount: Int
    let messageCount: Int

    var id: String { path }
}

struct DailyHeatmapBucket: Hashable {
    let date: Date
    var cost: Double
    var tokens: Int
}
