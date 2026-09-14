import XCTest
import Combine
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// The transcript view's window: what it materializes, what it throws away,
/// and that a full-history search neither misses rows nor grows the window.
@MainActor
final class TranscriptPagingModelTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("session.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPagingModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    /// `count` user turns, every tenth one mentioning "needle".
    private func writeTranscript(count: Int, body: String = "") throws {
        var data = Data()
        for index in 0..<count {
            let text = index % 10 == 0 ? "row \(index) needle \(body)" : "row \(index) \(body)"
            let entry: [String: Any] = [
                "type": "user", "timestamp": "2026-09-01T10:00:00Z",
                "message": ["content": text],
            ]
            data.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: root)
    }

    private func load(_ model: TranscriptPagingModel, paged: Bool = true) async {
        await model.load(
            path: root.path,
            provider: paged ? ClaudeProvider.shared : nil,
            wholeParse: { TranscriptParser.shared.parseMessages(at: self.root.path) }
        )
    }

    private func waitForRows(_ model: TranscriptPagingModel, atLeast count: Int) async {
        let filled = expectation(description: "rows materialized")
        let subscription = model.$rows.filter { $0.count >= count }.first().sink { _ in filled.fulfill() }
        await fulfillment(of: [filled], timeout: 5)
        subscription.cancel()
    }

    func testOutlineLoadsWithoutMaterializingAnyRow() async throws {
        try writeTranscript(count: 100)
        let model = TranscriptPagingModel()
        await load(model)

        XCTAssertTrue(model.isPaged)
        XCTAssertEqual(model.entries.count, 100)
        XCTAssertEqual(model.visibleEntries.count, 100)
        XCTAssertTrue(model.rows.isEmpty, "opening a transcript must not read message bodies")
    }

    func testRequestingARowMaterializesOnlyItsPage() async throws {
        try writeTranscript(count: 200)
        let model = TranscriptPagingModel(pageSize: 20)
        await load(model)

        model.requestRow(id: model.entries[45].id)
        await waitForRows(model, atLeast: 20)

        XCTAssertEqual(model.rows.count, 20)
        XCTAssertNotNil(model.row(id: model.entries[45].id))
        XCTAssertNil(model.row(id: model.entries[0].id))
        XCTAssertNil(model.row(id: model.entries[199].id))
    }

    func testWindowEvictsOldPagesOnceItsBudgetIsExceeded() async throws {
        try writeTranscript(count: 400, body: String(repeating: "z", count: 400))
        let model = TranscriptPagingModel(pageSize: 20, maxCachedPages: 3)
        await load(model)

        for page in 0..<8 {
            model.requestRow(id: model.entries[page * 20].id)
            await waitForRows(model, atLeast: 20)
        }
        // Settle: the last requests may still be in flight.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertLessThanOrEqual(model.rows.count, 3 * 20,
                                 "the resident window must stay inside its page budget")
        XCTAssertGreaterThan(model.rows.count, 0)
    }

    func testByteBudgetEvictsEvenWithFewPages() async throws {
        try writeTranscript(count: 200, body: String(repeating: "q", count: 2_000))
        let model = TranscriptPagingModel(pageSize: 20, maxCachedPages: 100, maxWindowBytes: 60_000)
        await load(model)

        for page in 0..<6 {
            model.requestRow(id: model.entries[page * 20].id)
            await waitForRows(model, atLeast: 20)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let residentBytes = model.rows.values.reduce(0) { $0 + $1.text.utf8.count }
        XCTAssertLessThan(residentBytes, 200_000, "byte budget must bound the window")
    }

    // MARK: - Search

    private func search(_ model: TranscriptPagingModel, _ query: String) async -> [String] {
        let done = expectation(description: "search finished")
        var result: [String] = []
        model.search(query: query) { matches, _ in
            result = matches
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        return result
    }

    func testSearchScansTheWholeHistoryAndMatchesTheWholeFileParse() async throws {
        try writeTranscript(count: 300)
        let model = TranscriptPagingModel(pageSize: 20)
        await load(model)

        let matches = await search(model, "needle")
        let expected = TranscriptParser.shared.parseMessages(at: root.path)
            .filter { SearchUtils.textMatches(query: "needle", in: SearchUtils.transcriptSearchableText(for: $0)) }
            .map(\.id)

        XCTAssertEqual(matches, expected)
        XCTAssertEqual(matches.count, 30)
    }

    func testSearchDoesNotGrowTheResidentWindow() async throws {
        try writeTranscript(count: 300, body: String(repeating: "w", count: 500))
        let model = TranscriptPagingModel(pageSize: 20)
        await load(model)
        XCTAssertTrue(model.rows.isEmpty)

        _ = await search(model, "needle")
        XCTAssertTrue(model.rows.isEmpty,
                      "a full-history scan must read and discard, not populate the window")
    }

    func testANewQueryReplacesTheRunningOne() async throws {
        try writeTranscript(count: 400)
        let model = TranscriptPagingModel(pageSize: 20)
        await load(model)

        model.search(query: "needle")
        let matches = await search(model, "row 7")

        XCTAssertEqual(model.searchState.query, "row 7")
        XCTAssertEqual(model.searchState.matchedIds, matches)
        XCTAssertFalse(model.searchState.isRunning)
    }

    func testFiltersNarrowSearchAndVisibleRows() async throws {
        try writeTranscript(count: 60)
        let model = TranscriptPagingModel(pageSize: 20)
        await load(model)

        model.toggleRole("assistant")
        XCTAssertTrue(model.visibleEntries.isEmpty, "no assistant rows in this fixture")
        let filtered = await search(model, "needle")
        XCTAssertEqual(filtered, [])

        model.clearFilters()
        XCTAssertEqual(model.visibleEntries.count, 60)
        let all = await search(model, "needle")
        XCTAssertEqual(all.count, 6)
    }

    func testAReplacedTranscriptRebuildsTheOutlineInsteadOfServingStaleRows() async throws {
        try writeTranscript(count: 200)
        let model = TranscriptPagingModel(pageSize: 20)
        await load(model)
        XCTAssertEqual(model.entries.count, 200)

        // Same byte offsets, different content: a page read from the new file
        // would parse fine and be wrong.
        try writeTranscript(count: 60, body: "replaced")
        model.requestRow(id: model.entries[100].id)

        let rebuilt = expectation(description: "outline rebuilt")
        let subscription = model.$entries.filter { $0.count == 60 }.first().sink { _ in rebuilt.fulfill() }
        await fulfillment(of: [rebuilt], timeout: 5)
        subscription.cancel()

        XCTAssertEqual(model.entries.count, 60)
        XCTAssertTrue(model.rows.values.allSatisfy { $0.text.contains("replaced") || $0.text.contains("needle") },
                      "no row may come from the replaced-away transcript")
    }

    // MARK: - Compatibility fallback

    func testProviderWithoutPagingStillLoadsAndSearches() async throws {
        try writeTranscript(count: 120)
        let model = TranscriptPagingModel(pageSize: 20)
        await load(model, paged: false)

        XCTAssertFalse(model.isPaged)
        XCTAssertEqual(model.entries.count, 120)
        XCTAssertEqual(model.rows.count, 120, "the fallback keeps its one whole-file parse")
        let matches = await search(model, "needle")
        XCTAssertEqual(matches.count, 12)
    }
}
