import XCTest
import Combine
import ClaudeStatisticsKit
@testable import Claude_Statistics

@MainActor
final class UsageTrendViewModelTests: XCTestCase {
    private let source = NSObject()
    private let start = Date(timeIntervalSince1970: 1_750_000_123)

    private actor Counter {
        var count = 0
        func increment() { count += 1 }
    }

    private actor Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var opened = false
        func wait() async {
            if !opened { await withCheckedContinuation { continuation = $0 } }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    private func input(_ index: Int = 0, version: UInt64 = 1, source: NSObject? = nil) -> UsageTrendViewModel.Input {
        let end = start.addingTimeInterval(3600 + Double(index))
        let request = UsageTrendRequest(source: ObjectIdentifier(source ?? self.source), version: version,
                                        windowStart: start, windowEnd: end, dataEnd: end,
                                        granularity: .hour, modelFilter: .all)
        return .init(request: request, stats: [:], pricing: ModelPricing.shared.snapshot())
    }

    private func load(_ input: UsageTrendViewModel.Input, into model: UsageTrendViewModel) async {
        let completed = expectation(description: "requested trend published")
        let subscription = model.$result.compactMap { $0 }.filter { $0.request == input.request }.first()
            .sink { _ in completed.fulfill() }
        model.request(input)
        await fulfillment(of: [completed], timeout: 3)
        subscription.cancel()
    }

    func testIdenticalRenderRequestsComputeOnceOffMainThread() async {
        let count = Counter()
        let model = UsageTrendViewModel { input in
            XCTAssertFalse(Thread.isMainThread)
            await count.increment()
            return .init(request: input.request, dataPoints: [], modelBreakdown: [])
        }
        let query = input()
        for _ in 0..<100 { model.request(query) }
        await load(query, into: model)
        for _ in 0..<100 { model.request(query) }
        let actual = await count.count
        XCTAssertEqual(actual, 1)
        XCTAssertEqual(model.cachedCount, 1)
    }

    func testBurstCoalescesPendingWorkAndRejectsOldSourceResult() async {
        let gate = Gate()
        let started = expectation(description: "old source started")
        let count = Counter()
        let model = UsageTrendViewModel { input in
            await count.increment()
            if input.request.version == 1 {
                started.fulfill()
                await gate.wait()
            }
            return .init(request: input.request, dataPoints: [], modelBreakdown: [])
        }
        model.request(input())
        await fulfillment(of: [started], timeout: 3)
        let replacementSource = NSObject()
        for version in 2...100 { model.request(input(version: UInt64(version), source: replacementSource)) }
        let latest = input(version: 100, source: replacementSource)
        await gate.open()
        await load(latest, into: model)
        let actual = await count.count
        XCTAssertEqual(actual, 2)
        XCTAssertEqual(model.result?.request, latest.request)
        XCTAssertEqual(model.cachedCount, 1)
    }

    func testCacheUsesLRUAndInvalidatesOnDataOrSourceChange() async {
        let count = Counter()
        let model = UsageTrendViewModel(cacheLimit: 2) { input in
            await count.increment()
            return .init(request: input.request, dataPoints: [], modelBreakdown: [])
        }
        for index in [0, 1, 0, 2, 1] { await load(input(index), into: model) }
        let afterEviction = await count.count
        XCTAssertEqual(afterEviction, 4)
        XCTAssertEqual(model.cachedCount, 2)
        await load(input(1, version: 2), into: model)
        XCTAssertEqual(model.cachedCount, 1)
        let otherSource = NSObject()
        await load(input(1, version: 2, source: otherSource), into: model)
        let afterInvalidation = await count.count
        XCTAssertEqual(afterInvalidation, 6)
        XCTAssertEqual(model.cachedCount, 1)
    }

    func testOversizedResultIsNotRetainedInCache() async {
        let model = UsageTrendViewModel(byteLimit: 100) { input in
            .init(request: input.request, dataPoints: [
                TrendDataPoint(time: input.request.windowStart, tokens: 0, cost: 0),
                TrendDataPoint(time: input.request.dataEnd, tokens: 1, cost: 1)
            ], modelBreakdown: [])
        }
        await load(input(), into: model)
        XCTAssertNotNil(model.result)
        XCTAssertEqual(model.cachedCount, 0)
        model.stop()
        XCTAssertNil(model.result)
    }

    func testStopClearsCacheAndRejectsNonCooperativeCompletion() async {
        let gate = Gate()
        let started = expectation(description: "calculation started")
        let model = UsageTrendViewModel { input in
            if input.request.version == 2 { started.fulfill(); await gate.wait() }
            return .init(request: input.request, dataPoints: [], modelBreakdown: [])
        }
        await load(input(), into: model)
        model.request(input(version: 2))
        await fulfillment(of: [started], timeout: 3)
        model.stop()
        XCTAssertNil(model.result)
        XCTAssertEqual(model.cachedCount, 0)
        await gate.open()
        // A fresh request waits for the cancelled operation to drain. Its
        // publication proves the old completion was processed and fenced.
        await load(input(version: 3), into: model)
        XCTAssertEqual(model.result?.request.version, 3)
        XCTAssertEqual(model.cachedCount, 1)
    }

    func testProjectionMatchesUnboundedFoldsForAllModelFilters() async throws {
        var stats = SessionStats()
        for index in 0..<48 {
            let model = ["claude-sonnet-4-6", "gemini-flash", "gemini-flash-lite", "gpt-5"][index % 4]
            let tokens = ModelTokenStats(inputTokens: 100 + index, outputTokens: 10, cacheReadTokens: 500, messageCount: 1)
            stats.fiveMinSlices[start.addingTimeInterval(Double(index) * 1800)] = DaySlice(
                totalInputTokens: tokens.inputTokens, totalOutputTokens: 10, cacheReadTokens: 500,
                messageCount: 1, modelBreakdown: [model: tokens])
        }
        stats.precomputeAggregates()
        let values = ["a": stats, "b": stats]
        let filters: [UsageTrendRequest.ModelFilter] = [.all, .matching("claude"), .matching("flash", excluding: "lite"), .matching("missing")]
        for filter in filters {
            let query = UsageTrendRequest(source: ObjectIdentifier(source), version: 1, windowStart: start,
                                          windowEnd: start.addingTimeInterval(86_400), dataEnd: start.addingTimeInterval(85_000),
                                          granularity: .hour, modelFilter: filter)
            let pricing = ModelPricing.shared.snapshot()
            let actual = try await UsageTrendViewModel.calculate(.init(request: query, stats: values, pricing: pricing))
            let predicate: ((String) -> Bool)? = filter == .all ? nil : filter.includes
            let expected = SessionTrendAggregator.windowTrendData(parsedStats: values, from: query.windowStart,
                to: query.dataEnd, granularity: query.granularity, cumulative: true, modelFilter: predicate, pricing: pricing)
            let models = SessionTrendAggregator.windowModelBreakdown(parsedStats: values, from: query.windowStart,
                to: query.dataEnd, modelFilter: predicate, pricing: pricing)
            XCTAssertEqual(actual.dataPoints.map(\.time), expected.map(\.time))
            XCTAssertEqual(actual.dataPoints.map(\.tokens), expected.map(\.tokens))
            for (a, e) in zip(actual.dataPoints, expected) { XCTAssertEqual(a.cost, e.cost, accuracy: 1e-8) }
            XCTAssertEqual(actual.modelBreakdown.map(\.model), models.map(\.model))
            XCTAssertEqual(actual.modelBreakdown.map(\.totalTokens), models.map(\.totalTokens))
            XCTAssertEqual(actual.modelBreakdown.map(\.sessionCount), models.map(\.sessionCount))
        }
    }

    func testLongWindowBoundsRenderedPointsWithoutChangingFinalTotals() {
        let tokens = ModelTokenStats(inputTokens: 1_000_000, messageCount: 1)
        var stats = SessionStats()
        stats.fiveMinSlices[start.addingTimeInterval(120)] = DaySlice(totalInputTokens: 1_000_000, modelBreakdown: ["unit-model": tokens])
        stats.precomputeAggregates()
        let pricing = ModelPricing.Pricing(input: 2, output: 10, cacheWrite5m: 2, cacheWrite1h: 2, cacheRead: 1)
        let snapshot = ModelPricing.Snapshot(models: ["unit-model": pricing], defaultPricing: pricing, date: start)
        let end = start.addingTimeInterval(7 * 86_400)
        let points = SessionTrendAggregator.windowTrendData(parsedStats: ["a": stats], from: start, to: end,
            granularity: .minute, cumulative: true, pricing: snapshot, maxPoints: 100)
        XCTAssertLessThanOrEqual(points.count, 100)
        XCTAssertEqual(points.first?.time, start)
        XCTAssertEqual(points.first?.tokens, 0)
        XCTAssertEqual(points.last?.time, end)
        XCTAssertEqual(points.last?.tokens, 1_000_000)
        XCTAssertEqual(points.last?.cost, 2)
        XCTAssertEqual(points.map(\.time), points.map(\.time).sorted())
    }
}
