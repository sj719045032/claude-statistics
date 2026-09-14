import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Long-run memory of transcript navigation on this machine's largest real
/// Claude transcripts: open each one, jump to the end and the start, sweep
/// through more pages than the window keeps, run a full-history search, close
/// it — several rounds. Live allocator bytes after later rounds must not keep
/// climbing past the first one, which fills one-time caches. Read-only.
/// Skipped unless `TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1`;
/// `TEST_RUNNER_CLAUDE_STATS_NAVIGATION_ROUNDS` sets the rounds (default 6).
@MainActor
final class TranscriptNavigationMemoryRealDataTests: XCTestCase {
    func testReopeningTranscriptsDoesNotAccumulateMemory() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_REAL_DATA"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_REAL_DATA=1")
        }
        let files = RealClaudeTranscripts.largest(4)
        try XCTSkipIf(files.isEmpty, "no local Claude transcripts")

        let rounds = max(3, Int(ProcessInfo.processInfo.environment["CLAUDE_STATS_NAVIGATION_ROUNDS"] ?? "6") ?? 6)
        var live: [Int] = []
        for _ in 0..<rounds {
            for file in files { await visit(file.url) }
            live.append(AllocationProbe.liveBytes())
        }

        let megabytes = live.map { String(format: "%.1f", Double($0) / 1_048_576) }
        print("[navigation-memory] transcripts=\(files.count) bytes=\(files.reduce(0) { $0 + $1.size }) " +
              "live_mb_per_round=\(megabytes.joined(separator: ","))")
        XCTAssertLessThan(live[live.count - 1] - live[1], 8 * 1_048_576,
                          "memory kept growing across rounds of the same navigation")
    }

    private func visit(_ file: URL) async {
        let model = TranscriptPagingModel()
        await model.load(path: file.path, provider: ClaudeProvider.shared, wholeParse: { [] })
        XCTAssertTrue(model.isPaged, file.lastPathComponent)
        let count = model.entries.count
        guard count > 0 else { return }

        let sweep = stride(from: 0, to: count, by: max(1, count / 30)).map { $0 }
        for index in [count - 1, 0] + sweep {
            let id = model.entries[index].id
            model.requestRow(id: id)
            let deadline = Date().addingTimeInterval(30)
            while model.row(id: id) == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertNotNil(model.row(id: id), "\(file.lastPathComponent) row \(index)")
        }
        XCTAssertLessThanOrEqual(model.rows.count, 12 * model.pageSize, "the window must stay bounded")

        let searched = expectation(description: "search finished")
        model.search(query: "the") { _, _ in searched.fulfill() }
        await fulfillment(of: [searched], timeout: 300)
        model.cancelAll()
    }
}
