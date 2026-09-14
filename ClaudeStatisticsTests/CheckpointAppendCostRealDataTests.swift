import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// What one append costs once a real Claude session has a checkpoint, split by
/// stage. The largest local Claude transcript is copied to a temp directory (the
/// original is only read) and committed to a temp database. Skipped unless
/// `TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1`.
final class CheckpointAppendCostRealDataTests: XCTestCase {
    func testAppendCostByStage() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_REAL_DATA"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_REAL_DATA=1")
        }
        let projects = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects"))
        let keys: [URLResourceKey] = [.fileSizeKey]
        var largest: (URL, Int)?
        for case let url as URL in FileManager.default.enumerator(at: projects, includingPropertiesForKeys: keys) ?? .init()
        where url.pathExtension == "jsonl" && !url.path.contains("/subagents/") {
            let size = (try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0
            if size > (largest?.1 ?? 0) { largest = (url, size) }
        }
        let source = try XCTUnwrap(largest).0

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppendCost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("session.jsonl")
        try FileManager.default.copyItem(at: source, to: root)

        let database = DatabaseService(databasePath: directory.appendingPathComponent("cost.db").path)
        database.open()
        defer { database.close() }

        func session() throws -> Session {
            let snapshot = try TranscriptFileSnapshot.read(at: root.path)
            return Session(id: "cost::session", externalID: "session", provider: "claude", projectPath: "cost",
                           filePath: root.path, startTime: nil, lastModified: snapshot.modifiedAt, fileSize: snapshot.size)
        }
        func parseAndCommit() async throws -> (parse: Double, save: Double) {
            let current = try session()
            let cached = database.loadAllCached(provider: .claude)[current.id]
            var start = CFAbsoluteTimeGetCurrent()
            let outcome = await SessionParseValidator.parse(provider: ClaudeProvider.shared, session: current,
                                                            quick: SessionQuickStats(), cached: cached, database: database)
            let parse = CFAbsoluteTimeGetCurrent() - start
            let request = try XCTUnwrap(outcome.saveRequest(for: current))
            start = CFAbsoluteTimeGetCurrent()
            XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request]))
            return (parse, CFAbsoluteTimeGetCurrent() - start)
        }

        _ = try await parseAndCommit()
        let record: [String: Any] = [
            "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["id": "msg-cost-\(UUID().uuidString)", "model": "claude-sonnet-4-6",
                        "content": [["type": "text", "text": "ok"]],
                        "usage": ["input_tokens": 10, "output_tokens": 5]],
        ]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: root)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()

        // Stages in isolation, on the committed checkpoint.
        var start = CFAbsoluteTimeGetCurrent()
        let previous = try XCTUnwrap(database.loadParseCheckpoint(provider: .claude, sessionId: "cost::session"))
        let loadMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        start = CFAbsoluteTimeGetCurrent()
        let update = try XCTUnwrap(ClaudeCheckpointParser.parse(at: root.path, checkpoint: previous))
        let parserMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        start = CFAbsoluteTimeGetCurrent()
        let encoded = try ParseCheckpointCoding.encode(update.checkpoint)
        let encodeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        start = CFAbsoluteTimeGetCurrent()
        _ = try ClaudeCheckpointParser.decodeState(update.checkpoint.state)
        let stateDecodeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        // The same append through the real pipeline.
        let pipeline = try await parseAndCommit()
        print("[append-cost] transcript_bytes=\(update.stats.messageCount > 0 ? try TranscriptFileSnapshot.read(at: root.path).size : 0) " +
              "messages=\(update.stats.messageCount) slices=\(update.stats.fiveMinSlices.count) " +
              "state_bytes=\(update.checkpoint.state.count) checkpoint_bytes=\(encoded.count) " +
              String(format: "load_checkpoint_ms=%.1f parser_ms=%.1f encode_checkpoint_ms=%.1f state_decode_ms=%.1f ",
                     loadMs, parserMs, encodeMs, stateDecodeMs) +
              String(format: "pipeline_parse_ms=%.1f pipeline_save_ms=%.1f", pipeline.parse * 1000, pipeline.save * 1000))
        XCTAssertEqual(update.bytesRead < 64 * 1024, true)
    }
}
