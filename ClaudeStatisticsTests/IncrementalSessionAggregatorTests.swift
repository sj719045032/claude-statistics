import XCTest
import ClaudeStatisticsKit
@testable import Claude_Statistics

final class IncrementalSessionAggregatorTests: XCTestCase {
    private let model = "claude-sonnet-4-6"

    private func stats(_ count: Int, start: Date = Date(timeIntervalSince1970: 1_750_000_000), model: String? = nil) -> SessionStats {
        let model = model ?? self.model
        var result = SessionStats()
        result.model = model
        result.startTime = start
        for index in 0..<count {
            let tokens = ModelTokenStats(inputTokens: 100 + index, outputTokens: 20, cacheCreation5mTokens: 30,
                                        cacheCreationTotalTokens: 30, cacheReadTokens: 400, messageCount: 1)
            result.fiveMinSlices[start.addingTimeInterval(Double(index) * 3600)] = DaySlice(
                totalInputTokens: tokens.inputTokens, totalOutputTokens: tokens.outputTokens,
                cacheCreation5mTokens: 30, cacheCreationTotalTokens: 30, cacheReadTokens: 400,
                messageCount: 2, toolUseCounts: ["read": 1], modelBreakdown: [model: tokens])
        }
        result.precomputeAggregates()
        return result
    }

    private func sessions(_ values: [String: SessionStats], project: String = "/project") -> [Session] {
        values.map { id, stats in
            Session(id: id, externalID: id, provider: "claude", projectPath: project, filePath: "",
                    startTime: stats.startTime, lastModified: stats.startTime ?? .distantPast, fileSize: 0)
        }
    }

    private func input(_ values: [String: SessionStats], versions: [String: UInt64], period: StatsPeriod = .all,
                       reset: Date? = nil, project: String = "/project", pricing: ModelPricing.Snapshot? = nil,
                       calendar: Calendar = .current) -> IncrementalSessionAggregator.Input {
        .init(stats: values, revisions: versions, sessions: sessions(values, project: project), period: period,
              weeklyResetDate: reset, allTimeLabel: "All", pricing: pricing ?? ModelPricing.shared.snapshot(), calendar: calendar)
    }

    /// Independent full fold using the original PeriodStats accumulator.
    private func reference(_ values: [String: SessionStats], period: StatsPeriod, reset: Date?) -> [PeriodStats] {
        var buckets: [Date: PeriodStats] = [:]
        var memberships: [Date: Set<String>] = [:]
        var modelMemberships: [Date: [String: Set<String>]] = [:]
        if period == .all { buckets[.distantPast] = PeriodStats(period: .distantPast, periodLabel: "All", chartLabel: "All") }
        for (id, stats) in values {
            let slices = period == .all || (period == .weekly && reset != nil) ? stats.fiveMinSlices : stats.daySlices
            if slices.isEmpty {
                let key = period.startOfPeriod(for: stats.startTime ?? .distantPast, weeklyResetDate: reset)
                if buckets[key] == nil { buckets[key] = PeriodStats(period: key, periodLabel: "", chartLabel: "") }
                buckets[key]!.accumulate(stats: stats)
                memberships[key, default: []].insert(id)
                modelMemberships[key, default: [:]][stats.model, default: []].insert(id)
            } else {
                for (time, slice) in slices {
                    let key = period.startOfPeriod(for: time, weeklyResetDate: reset)
                    if buckets[key] == nil { buckets[key] = PeriodStats(period: key, periodLabel: "", chartLabel: "") }
                    buckets[key]!.accumulate(daySlice: slice)
                    memberships[key, default: []].insert(id)
                    for model in slice.modelBreakdown.keys { modelMemberships[key, default: [:]][model, default: []].insert(id) }
                }
            }
        }
        for key in buckets.keys {
            buckets[key]!.sessionCount = memberships[key]?.count ?? 0
            for (model, ids) in modelMemberships[key] ?? [:] { buckets[key]!.modelBreakdown[model]?.sessionCount = ids.count }
        }
        return buckets.values.sorted { $0.period > $1.period }
    }

    private func assertPeriods(_ actual: [PeriodStats], _ expected: [PeriodStats], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.period), expected.map(\.period), file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.totalTokens, b.totalTokens, file: file, line: line)
            XCTAssertEqual(a.totalCost, b.totalCost, accuracy: 1e-8, file: file, line: line)
            XCTAssertEqual(a.sessionCount, b.sessionCount, file: file, line: line)
            XCTAssertEqual(a.messageCount, b.messageCount, file: file, line: line)
            XCTAssertEqual(a.toolUseCounts, b.toolUseCounts, file: file, line: line)
            XCTAssertEqual(a.hasEstimatedCost, b.hasEstimatedCost, file: file, line: line)
            XCTAssertEqual(Set(a.modelBreakdown.keys), Set(b.modelBreakdown.keys), file: file, line: line)
            for (model, usage) in a.modelBreakdown {
                guard let expected = b.modelBreakdown[model] else { continue }
                XCTAssertEqual(usage.totalTokens, expected.totalTokens, file: file, line: line)
                XCTAssertEqual(usage.cacheReadTokens, expected.cacheReadTokens, file: file, line: line)
                XCTAssertEqual(usage.sessionCount, expected.sessionCount, file: file, line: line)
                XCTAssertEqual(usage.messageCount, expected.messageCount, file: file, line: line)
                XCTAssertEqual(usage.cost, expected.cost, accuracy: 1e-8, file: file, line: line)
                XCTAssertEqual(usage.isEstimated, expected.isEstimated, file: file, line: line)
            }
        }
    }

    func testIncrementalReplacementAndDeletionEqualFullFoldForEveryPeriod() async throws {
        for period in StatsPeriod.allCases {
            let engine = IncrementalSessionAggregator()
            let reset = period == .weekly ? Date(timeIntervalSince1970: 1_750_010_400) : nil
            var values = ["a": stats(40), "b": stats(80), "empty": SessionStats()]
            var versions: [String: UInt64] = ["a": 1, "b": 1, "empty": 1]
            let first = try await engine.update(input(values, versions: versions, period: period, reset: reset))
            assertPeriods(first.periods, reference(values, period: period, reset: reset))
            XCTAssertEqual(first.visitedSlices, 120)
            values["a"] = stats(45, model: "unknown-test-model")
            versions["a"] = 2
            let second = try await engine.update(input(values, versions: versions, period: period, reset: reset))
            assertPeriods(second.periods, reference(values, period: period, reset: reset))
            XCTAssertEqual(second.updatedSessions, 1)
            XCTAssertEqual(second.visitedSlices, 45)
            values["b"] = nil
            versions["b"] = nil
            let deleted = try await engine.update(input(values, versions: versions, period: period, reset: reset))
            assertPeriods(deleted.periods, reference(values, period: period, reset: reset))
            XCTAssertEqual(deleted.visitedSlices, 0)
            XCTAssertEqual(deleted.updatedSessions, 1)
            let full = try SessionAllTimeAggregator.allTimeAggregates(parsedStats: values, sessions: sessions(values))
            XCTAssertEqual(Set(deleted.heatmap.keys), Set(full.dailyHeatmap.keys))
            for (date, bucket) in deleted.heatmap {
                XCTAssertEqual(bucket.tokens, full.dailyHeatmap[date]?.tokens)
                XCTAssertEqual(bucket.cost, full.dailyHeatmap[date]!.cost, accuracy: 1e-8)
            }
            XCTAssertEqual(deleted.projects.map(\.tokens), full.topProjects.map(\.tokens))
            XCTAssertEqual(deleted.projects.map(\.sessionCount), full.topProjects.map(\.sessionCount))
        }
    }

    func testNoOpAndRepricingDoNotVisitHistoricalSlices() async throws {
        let engine = IncrementalSessionAggregator()
        let values = ["a": stats(100)]
        let first = try await engine.update(input(values, versions: ["a": 1]))
        let noOp = try await engine.update(input(values, versions: ["a": 1]))
        XCTAssertEqual(noOp.updatedSessions, 0)
        XCTAssertEqual(noOp.visitedSlices, 0)
        let p = ModelPricing.Pricing(input: 20, output: 100, cacheWrite5m: 25, cacheWrite1h: 40, cacheRead: 2)
        let rates = ModelPricing.Snapshot(models: [model: p], defaultPricing: p, date: Date())
        let repriced = try await engine.update(input(values, versions: ["a": 1], pricing: rates))
        XCTAssertEqual(repriced.updatedSessions, 0)
        XCTAssertEqual(repriced.visitedSlices, 0)
        XCTAssertEqual(repriced.allTime.totalTokens, first.allTime.totalTokens)
        XCTAssertNotEqual(repriced.allTime.totalCost, first.allTime.totalCost)
        XCTAssertEqual(repriced.projects[0].cost, repriced.allTime.totalCost, accuracy: 1e-8)
    }

    func testProjectMetadataChangeMovesContributionWithoutDoubleCounting() async throws {
        let engine = IncrementalSessionAggregator()
        let values = ["a": stats(10)]
        _ = try await engine.update(input(values, versions: ["a": 1], project: "/old"))
        let changed = try await engine.update(input(values, versions: ["a": 1], project: "/new"))
        XCTAssertEqual(changed.projects.map(\.path), ["/new"])
        XCTAssertEqual(changed.allTime.sessionCount, 1)
        XCTAssertEqual(changed.allTime.totalTokens, values["a"]!.totalTokens)
        let empty = try await engine.update(input([:], versions: [:]))
        XCTAssertTrue(empty.projects.isEmpty)
        XCTAssertTrue(empty.heatmap.isEmpty)
        XCTAssertTrue(empty.allTime.modelBreakdown.isEmpty)
        XCTAssertEqual(empty.allTime.totalCost, 0)
    }

    func testTimezoneRebuildsDailyAttributionFromFiveMinuteSource() async throws {
        let engine = IncrementalSessionAggregator()
        let values = ["a": stats(1, start: Date(timeIntervalSince1970: 1_750_035_600))]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var pacific = utc
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let first = try await engine.update(input(values, versions: ["a": 1], period: .daily, calendar: utc))
        let second = try await engine.update(input(values, versions: ["a": 1], period: .daily, calendar: pacific))
        XCTAssertEqual(second.updatedSessions, 1)
        XCTAssertEqual(second.visitedSlices, 1)
        XCTAssertNotEqual(first.periods[0].period, second.periods[0].period)
        XCTAssertEqual(second.periods[0].period, pacific.startOfDay(for: values["a"]!.startTime!))
        XCTAssertEqual(second.allTime.totalTokens, first.allTime.totalTokens)
    }

    func testOneUpdateInLargeHistoryTouchesOnlyThatSession() async throws {
        let engine = IncrementalSessionAggregator()
        var values = Dictionary(uniqueKeysWithValues: (0..<400).map { ("s\($0)", stats(100)) })
        var versions = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, UInt64(1)) })
        let first = try await engine.update(input(values, versions: versions))
        XCTAssertEqual(first.visitedSlices, 40_000)
        values["s5"] = stats(101)
        versions["s5"] = 2
        let result = try await engine.update(input(values, versions: versions))
        XCTAssertEqual(result.updatedSessions, 1)
        XCTAssertEqual(result.visitedSlices, 101)
        XCTAssertEqual(result.allTime.totalTokens, values.values.reduce(0) { $0 + $1.totalTokens })
        print("Aggregate delta: history_slices=40000, changed_sessions=\(result.updatedSessions), visited_slices=\(result.visitedSlices)")
    }

    func testRepeatedModelAndDayChangesLeaveNoResidualContributions() async throws {
        let engine = IncrementalSessionAggregator()
        for revision in 1...100 {
            let value = stats(revision % 7 + 1,
                              start: Date(timeIntervalSince1970: 1_750_000_000 + Double(revision) * 86400),
                              model: revision % 2 == 0 ? model : "unknown-test-model")
            let output = try await engine.update(input(["a": value], versions: ["a": UInt64(revision)], period: .daily))
            assertPeriods(output.periods, reference(["a": value], period: .daily, reset: nil))
            XCTAssertEqual(output.allTime.sessionCount, 1)
            XCTAssertEqual(Set(output.allTime.modelBreakdown.keys), [value.model])
            XCTAssertEqual(output.allTime.hasEstimatedCost, !ModelPricing.shared.isExactMatch(for: value.model))
            XCTAssertEqual(output.heatmap.values.reduce(0) { $0 + $1.tokens }, value.totalTokens)
        }
    }

    func testCancelledUpdateDoesNotPoisonNextSnapshot() async throws {
        let engine = IncrementalSessionAggregator()
        let values = ["a": stats(100)]
        let snapshot = input(values, versions: ["a": 1])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.update(snapshot)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let recovered = try await engine.update(snapshot)
        assertPeriods(recovered.periods, reference(values, period: .all, reset: nil))
    }
}
