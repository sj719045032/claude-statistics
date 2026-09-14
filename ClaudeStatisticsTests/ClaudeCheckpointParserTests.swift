import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

final class ClaudeCheckpointParserTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("session.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCheckpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func assistant(_ id: String, tokens: Int, model: String = "claude-sonnet-4-6",
                           text: String = "answer", time: String = "2026-09-01T10:01:00Z",
                           tool: Bool = false) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if tool { content.append(["type": "tool_use", "id": "tool-1", "name": "Read", "input": ["file_path": "source.swift"]]) }
        return ["type": "assistant", "timestamp": time,
                "message": ["id": id, "model": model, "content": content,
                            "usage": ["input_tokens": tokens, "output_tokens": tokens / 2,
                                      "cache_creation_input_tokens": 3, "cache_read_input_tokens": 4,
                                      "cache_creation": ["ephemeral_5m_input_tokens": 1, "ephemeral_1h_input_tokens": 2]]]]
    }

    private func user(_ text: String) -> [String: Any] {
        ["type": "user", "timestamp": "2026-09-01T10:00:00Z", "message": ["content": text]]
    }

    private func data(_ entries: [[String: Any]]) throws -> Data {
        var result = Data()
        for entry in entries {
            result.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            result.append(0x0A)
        }
        return result
    }

    private func write(_ entries: [[String: Any]], to file: URL? = nil) throws {
        let file = file ?? root
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(entries).write(to: file)
    }

    private func append(_ data: Data, to file: URL? = nil) throws {
        let handle = try FileHandle(forWritingTo: file ?? root)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func parse(_ checkpoint: SessionParseCheckpoint? = nil) throws -> CheckpointedSessionUpdate {
        try XCTUnwrap(ClaudeCheckpointParser.parse(at: root.path, checkpoint: checkpoint))
    }

    private func assertSame(_ first: SessionStats, _ second: SessionStats, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second), file: file, line: line)
        XCTAssertEqual(first.estimatedCost, second.estimatedCost, accuracy: 0.0000001, file: file, line: line)
    }

    func testFullParseMatchesExistingTokensToolsModelsAndPreview() throws {
        try write([user("hello"), assistant("a", tokens: 10, tool: true),
                   assistant("a", tokens: 20, text: "finished", tool: true),
                   user("second question"), assistant("b", tokens: 30, model: "claude-opus-4-6")])
        let update = try parse()
        try assertSame(update.stats, TranscriptParser.shared.parseSession(at: root.path))
        XCTAssertEqual(update.quickStats.topic, "hello")
        XCTAssertEqual(update.quickStats.totalTokens, update.stats.totalTokens)
        XCTAssertEqual(update.quickStats.lastOutputPreview, update.stats.lastOutputPreview)
        XCTAssertNil(try ClaudeCheckpointParser.parse(at: root.path, checkpoint: update.checkpoint))
    }

    func testStreamingRevisionAcrossRestartReplacesUsageAndSearch() throws {
        try write([user("question"), assistant("a", tokens: 10, text: "obsoleteword", tool: true)])
        let initial = try parse()
        // Codable round trip is the exact state handed back after app restart.
        let restored = try JSONDecoder().decode(SessionParseCheckpoint.self, from: JSONEncoder().encode(initial.checkpoint))
        try append(data([assistant("a", tokens: 50, model: "claude-opus-4-6", text: "replacementword",
                                   time: "2026-09-02T12:05:00Z", tool: true)]))
        let updated = try parse(restored)
        try assertSame(updated.stats, TranscriptParser.shared.parseSession(at: root.path))
        XCTAssertEqual(updated.stats.assistantMessageCount, 1)
        XCTAssertEqual(updated.stats.toolUseTotal, 1)
        let db = DatabaseService(databasePath: directory.appendingPathComponent("cache.db").path)
        db.open()
        defer { db.close() }
        for value in [initial, updated] {
            XCTAssertTrue(db.saveSessionsStatsAndIndexes(provider: .claude, requests: [
                .init(sessionId: "session", fileSize: value.checkpoint.sources[root.path]!.snapshot.size,
                      mtime: value.checkpoint.sources[root.path]!.snapshot.modifiedAt, stats: value.stats,
                      searchIndexUpdate: value.searchIndex, checkpoint: value.checkpoint)
            ]))
        }
        XCTAssertTrue(db.search(query: "obsoleteword", provider: .claude).isEmpty)
        XCTAssertEqual(db.search(query: "replacementword", provider: .claude).count, 1)
        XCTAssertEqual(db.search(query: "question", provider: .claude).count, 1)
    }

    func testArbitraryByteBatchesAndPartialUTF8HaveFullParseEquivalence() throws {
        let payload = try data([user("你好 🌿"), assistant("a", tokens: 10), assistant("a", tokens: 30, text: "最终回答")])
        for batchSize in [1, 7, 127] {
            try Data().write(to: root)
            var checkpoint: SessionParseCheckpoint?
            var latest: SessionStats?
            for start in stride(from: 0, to: payload.count, by: batchSize) {
                try append(payload.subdata(in: start..<min(start + batchSize, payload.count)))
                let update = try parse(checkpoint)
                checkpoint = try JSONDecoder().decode(SessionParseCheckpoint.self, from: JSONEncoder().encode(update.checkpoint))
                latest = update.stats
            }
            try assertSame(try XCTUnwrap(latest), TranscriptParser.shared.parseSession(at: root.path))
            XCTAssertEqual(checkpoint?.sources[root.path]?.offset, Int64(payload.count))
        }
    }

    func testCompleteFinalLineWithoutNewlineIsAcceptedButPartialLineIsDeferred() throws {
        let first = try data([assistant("a", tokens: 10)])
        try first.dropLast().write(to: root)
        let initial = try parse()
        XCTAssertEqual(initial.stats.totalInputTokens, 10)
        let next = try data([assistant("b", tokens: 20)])
        try append(Data([0x0A]) + next.prefix(25))
        let partial = try parse(initial.checkpoint)
        XCTAssertEqual(partial.stats.totalInputTokens, 10)
        XCTAssertEqual(partial.checkpoint.sources[root.path]?.offset, Int64(first.count))
        try append(Data(next.dropFirst(25)))
        let final = try parse(partial.checkpoint)
        try assertSame(final.stats, TranscriptParser.shared.parseSession(at: root.path))
    }

    func testChildAppendAndDeletionReconcileWithoutReadingMainHistory() throws {
        try write([user("main"), assistant("main-id", tokens: 10)])
        let child = directory.appendingPathComponent("session/subagents/agent.jsonl")
        try write([assistant("main-id", tokens: 999), assistant("child-id", tokens: 20)], to: child)
        let initial = try parse()
        XCTAssertEqual(initial.stats.totalInputTokens, 30, "main owns duplicate IDs")
        let addition = try data([assistant("child-id", tokens: 40), assistant("child-2", tokens: 60)])
        try append(addition, to: child)
        let updated = try parse(initial.checkpoint)
        try assertSame(updated.stats, TranscriptParser.shared.parseSession(at: root.path))
        XCTAssertEqual(updated.stats.totalInputTokens, 110)
        XCTAssertEqual(try XCTUnwrap(updated.checkpoint.sources[root.path]).snapshot,
                       try XCTUnwrap(initial.checkpoint.sources[root.path]).snapshot)
        XCTAssertLessThanOrEqual(updated.bytesRead, Int64(addition.count + 4096))
        try FileManager.default.removeItem(at: child)
        let deleted = try parse(updated.checkpoint)
        XCTAssertEqual(deleted.bytesRead, 0)
        try assertSame(deleted.stats, TranscriptParser.shared.parseSession(at: root.path))
    }

    func testReplacingMainPreservesChildAndReleasesDuplicateOwnership() throws {
        try write([assistant("shared", tokens: 10)])
        let child = directory.appendingPathComponent("session/subagents/agent.jsonl")
        try write([assistant("shared", tokens: 20)], to: child)
        let initial = try parse()
        try data([user("replaced main"), assistant("new", tokens: 30)]).write(to: root, options: .atomic)
        let updated = try parse(initial.checkpoint)
        XCTAssertEqual(updated.stats.totalInputTokens, 50)
        try assertSame(updated.stats, TranscriptParser.shared.parseSession(at: root.path))
        XCTAssertEqual(try XCTUnwrap(updated.checkpoint.sources[child.path]).snapshot,
                       try XCTUnwrap(initial.checkpoint.sources[child.path]).snapshot)
        guard case .replaceIdentified = updated.searchIndex else { return XCTFail("main replacement must replace index") }
    }

    func testInPlaceTruncateAndRegrowChecksContinuityInsteadOfAddingOldTokens() throws {
        try write([assistant("a", tokens: 10)])
        let initial = try parse()
        let replacement = try data([assistant("b", tokens: 50, text: String(repeating: "new", count: 100))])
        let handle = try FileHandle(forWritingTo: root)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()
        let updated = try parse(initial.checkpoint)
        XCTAssertEqual(updated.stats.totalInputTokens, 50)
        try assertSame(updated.stats, TranscriptParser.shared.parseSession(at: root.path))
        XCTAssertTrue(updated.checkpoint.sources[root.path]!.snapshot.hasSameIdentity(as: initial.checkpoint.sources[root.path]!.snapshot))
    }

    func testChildWithoutModelFollowsFinalMainModelAfterAppend() throws {
        try write([assistant("a", tokens: 10)])
        var childEntry = assistant("b", tokens: 20)
        var message = childEntry["message"] as! [String: Any]
        message.removeValue(forKey: "model")
        childEntry["message"] = message
        try write([childEntry], to: directory.appendingPathComponent("session/subagents/a.jsonl"))
        let initial = try parse()
        try append(data([assistant("c", tokens: 30, model: "claude-opus-4-6")]))
        let updated = try parse(initial.checkpoint)
        try assertSame(updated.stats, TranscriptParser.shared.parseSession(at: root.path))
        XCTAssertEqual(updated.stats.modelBreakdown["claude-opus-4-6"]?.inputTokens, 50)
    }

    func testAppendReadsDeltaPlusBoundedContinuitySamplesNotOldHistory() throws {
        let ignoredLine = "{\"type\":\"progress\",\"data\":\"" + String(repeating: "x", count: 1000) + "\"}\n"
        try Data(String(repeating: ignoredLine, count: 4096).utf8).write(to: root)
        try append(data([assistant("a", tokens: 10)]))
        let initial = try parse()
        let addition = try data([assistant("b", tokens: 20)])
        try append(addition)
        let updated = try parse(initial.checkpoint)
        XCTAssertEqual(updated.bytesRead, Int64(addition.count + 4096))
        XCTAssertEqual(updated.stats.totalInputTokens, 30)
        XCTAssertLessThan(updated.checkpoint.state.count, 20_000, "raw history must not be stored in checkpoint state")
    }

    func testNoUsageAssistantRevisionsCountOnce() throws {
        let entry: [String: Any] = ["type": "assistant", "timestamp": "2026-09-01T10:01:00Z",
                                   "message": ["id": "a", "content": "thinking reply"]]
        try write([entry])
        let initial = try parse()
        try append(data([entry, assistant("a", tokens: 10)]))
        let updated = try parse(initial.checkpoint)
        XCTAssertEqual(updated.stats.assistantMessageCount, 1)
        try assertSame(updated.stats, try parse().stats)
    }

    func testRealProviderThroughHostValidatorPersistsIndependentChildOffsets() async throws {
        try write([user("question"), assistant("main", tokens: 10)])
        let child = directory.appendingPathComponent("session/subagents/agent.jsonl")
        try write([assistant("child", tokens: 20)], to: child)
        let db = DatabaseService(databasePath: directory.appendingPathComponent("host.db").path)
        db.open()
        defer { db.close() }
        for expected in [30, 60] {
            if expected == 60 {
                db.close()
                db.open()
                try append(data([assistant("child", tokens: 50)]), to: child)
            }
            let snapshot = try TranscriptFileSnapshot.read(at: root.path)
            let childSnapshot = try TranscriptFileSnapshot.read(at: child.path)
            let session = Session(id: "test::session", externalID: "session", provider: "claude", projectPath: "test",
                                  filePath: root.path, startTime: nil, lastModified: snapshot.modifiedAt,
                                  fileSize: snapshot.size + childSnapshot.size)
            let cached = db.loadAllCached(provider: .claude)[session.id]
            let outcome = await SessionParseValidator.parse(provider: ClaudeProvider.shared, session: session,
                                                           quick: SessionQuickStats(), cached: cached, database: db)
            XCTAssertFalse(outcome.shouldRetry)
            XCTAssertEqual(outcome.committedStats?.totalInputTokens, expected)
            XCTAssertTrue(db.saveSessionsStatsAndIndexes(provider: .claude, requests: [try XCTUnwrap(outcome.saveRequest(for: session))]))
            let checkpoint = try XCTUnwrap(db.loadParseCheckpoint(provider: .claude, sessionId: session.id))
            XCTAssertEqual(checkpoint.sources[root.path]?.offset, snapshot.size)
            XCTAssertEqual(checkpoint.sources[child.path]?.offset, childSnapshot.size,
                           "expected \(child.path), keys: \(checkpoint.sources.keys.sorted())")
            XCTAssertEqual(db.search(query: "question", provider: .claude).count, 1)
        }
    }
}
