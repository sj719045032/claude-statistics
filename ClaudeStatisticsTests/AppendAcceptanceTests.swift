import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Acceptance gate "appending to a 1 GB JSONL reads proportional to the
/// append", measured end to end: the real Claude provider, the host's parse
/// validator and a real database, not the reader alone. Heavy (it writes and
/// parses about 1 GiB), so it is skipped unless enabled:
///
///     TEST_RUNNER_CLAUDE_STATS_ACCEPTANCE=1 bash scripts/run-tests.sh
final class AppendAcceptanceTests: XCTestCase {
    func testOneGigabyteHistoryAppendReadsOnlyTheAppendThroughThePipeline() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_ACCEPTANCE=1")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppendAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("session.jsonl")

        // ~1 GiB of real assistant records, written a chunk at a time.
        func record(_ index: Int) -> Data {
            let entry: [String: Any] = [
                "type": "assistant", "timestamp": "2026-09-11T01:00:00Z",
                "message": ["id": "msg-\(index)", "model": "claude-sonnet-4-6",
                            "content": [["type": "text", "text": String(repeating: "x", count: 8_000)]],
                            "usage": ["input_tokens": 10, "output_tokens": 5]],
            ]
            var data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            return data
        }
        FileManager.default.createFile(atPath: root.path, contents: nil)
        let writer = try FileHandle(forWritingTo: root)
        var index = 0
        var written: Int64 = 0
        while written < 1 << 30 {
            var chunk = Data()
            while chunk.count < 8 << 20 {
                chunk.append(record(index))
                index += 1
            }
            try writer.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
        try writer.close()

        let database = DatabaseService(databasePath: directory.appendingPathComponent("acceptance.db").path)
        database.open()
        defer { database.close() }

        func parseAndCommit() async throws -> (bytesRead: Int64, seconds: Double) {
            let snapshot = try TranscriptFileSnapshot.read(at: root.path)
            let session = Session(id: "acceptance::session", externalID: "session", provider: "claude",
                                  projectPath: "acceptance", filePath: root.path, startTime: nil,
                                  lastModified: snapshot.modifiedAt, fileSize: snapshot.size)
            let cached = database.loadAllCached(provider: .claude)[session.id]
            let start = CFAbsoluteTimeGetCurrent()
            let outcome = await SessionParseValidator.parse(provider: ClaudeProvider.shared, session: session,
                                                            quick: SessionQuickStats(), cached: cached, database: database)
            let seconds = CFAbsoluteTimeGetCurrent() - start
            let update = try XCTUnwrap(outcome.checkpointUpdate)
            XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude,
                                                               requests: [try XCTUnwrap(outcome.saveRequest(for: session))]))
            return (update.bytesRead, seconds)
        }

        let initial = try await parseAndCommit()
        let history = try TranscriptFileSnapshot.read(at: root.path).size

        let append = record(index)
        let handle = try FileHandle(forWritingTo: root)
        try handle.seekToEnd()
        try handle.write(contentsOf: append)
        try handle.close()

        let incremental = try await parseAndCommit()
        print("[acceptance] history=\(history) initial_read=\(initial.bytesRead) initial_seconds=\(String(format: "%.1f", initial.seconds)) " +
              "append=\(append.count) append_read=\(incremental.bytesRead) append_ms=\(String(format: "%.1f", incremental.seconds * 1000))")

        XCTAssertGreaterThanOrEqual(history, 1 << 30)
        // The append plus bounded continuity samples — never the history.
        XCTAssertLessThan(incremental.bytesRead, Int64(append.count) + 16 * 1024)
    }
}
