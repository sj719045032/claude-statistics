import XCTest

@testable import Claude_Statistics

/// Coverage for `TranscriptParser.parseSession(at:)` — the Claude Code
/// JSONL → SessionStats parser. Tests use real on-disk fixture files
/// because the parser reads via `FileManager.default.contents(atPath:)`
/// and processes the bytes line-by-line.
///
/// Each test crafts a minimal JSONL that exercises one specific facet
/// (user/assistant counts, token aggregation, tool tracking, dedup,
/// preview extraction, etc.). The full Claude payload schema is much
/// richer; we only emit the fields the parser actually reads.
final class TranscriptParserTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptParserTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeJSONL(_ lines: [[String: Any]], filename: String = "session.jsonl") -> String {
        let path = tempDir.appendingPathComponent(filename).path
        let content = lines
            .map { try! String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func userEntry(text: String, timestamp: String = "2026-04-25T10:00:00.000Z") -> [String: Any] {
        [
            "type": "user",
            "timestamp": timestamp,
            "message": ["content": text],
        ]
    }

    private func assistantEntry(
        id: String,
        model: String = "claude-sonnet-4-6",
        timestamp: String = "2026-04-25T10:01:00.000Z",
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        text: String? = nil,
        toolUses: [(name: String, id: String)] = []
    ) -> [String: Any] {
        var content: [[String: Any]] = []
        if let text { content.append(["type": "text", "text": text]) }
        for use in toolUses {
            content.append(["type": "tool_use", "name": use.name, "id": use.id, "input": [:]])
        }
        return [
            "type": "assistant",
            "timestamp": timestamp,
            "message": [
                "id": id,
                "model": model,
                "usage": [
                    "input_tokens": inputTokens,
                    "output_tokens": outputTokens,
                    "cache_creation_input_tokens": cacheCreation,
                    "cache_read_input_tokens": cacheRead,
                ],
                "content": content,
            ],
        ]
    }

    // MARK: - Empty / malformed input

    func test_missingFile_returnsEmptyStats() {
        let stats = TranscriptParser.shared.parseSession(at: "/nonexistent/path.jsonl")
        XCTAssertEqual(stats.userMessageCount, 0)
        XCTAssertEqual(stats.assistantMessageCount, 0)
        XCTAssertEqual(stats.totalTokens, 0)
        XCTAssertNil(stats.startTime)
    }

    func test_malformedLines_areSkipped() {
        let path = tempDir.appendingPathComponent("bad.jsonl").path
        try? "not json\n{also not\n".write(toFile: path, atomically: true, encoding: .utf8)
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 0)
        XCTAssertEqual(stats.assistantMessageCount, 0)
    }

    // MARK: - Counts

    func test_userAndAssistantCounts() {
        let path = writeJSONL([
            userEntry(text: "hi"),
            assistantEntry(id: "m1", outputTokens: 10),
            userEntry(text: "again"),
            assistantEntry(id: "m2", outputTokens: 5),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 2)
        XCTAssertEqual(stats.assistantMessageCount, 2)
    }

    // MARK: - Streaming dedup (same message id appearing twice)

    func test_duplicateAssistantMessageId_isCountedOnce() {
        // Streaming sends partial usage then final usage under the same
        // message id. Counts must NOT double; tokens take last-write-wins.
        let path = writeJSONL([
            assistantEntry(id: "stream-msg", outputTokens: 5),
            assistantEntry(id: "stream-msg", outputTokens: 50),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.assistantMessageCount, 1)
        XCTAssertEqual(stats.totalOutputTokens, 50, "later entry must overwrite earlier (last wins)")
    }

    // MARK: - Token aggregation

    func test_tokenSums() {
        let path = writeJSONL([
            assistantEntry(id: "m1", inputTokens: 100, outputTokens: 50, cacheCreation: 10, cacheRead: 5),
            assistantEntry(id: "m2", inputTokens: 200, outputTokens: 80, cacheCreation: 20, cacheRead: 10),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.totalInputTokens, 300)
        XCTAssertEqual(stats.totalOutputTokens, 130)
        XCTAssertEqual(stats.cacheCreationTotalTokens, 30)
        XCTAssertEqual(stats.cacheReadTokens, 15)
    }

    // MARK: - Model tracking

    func test_lastNonSyntheticModelWins() {
        let path = writeJSONL([
            assistantEntry(id: "m1", model: "claude-sonnet-4-6", outputTokens: 1),
            assistantEntry(id: "m2", model: "<synthetic>", outputTokens: 1),
            assistantEntry(id: "m3", model: "claude-opus-4-7", outputTokens: 1),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.model, "claude-opus-4-7")
    }

    func test_syntheticModelDoesNotOverrideRealOne() {
        let path = writeJSONL([
            assistantEntry(id: "m1", model: "claude-sonnet-4-6", outputTokens: 1),
            assistantEntry(id: "m2", model: "<synthetic>", outputTokens: 1),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.model, "claude-sonnet-4-6")
    }

    // MARK: - Tool tracking

    func test_toolUseCount() {
        let path = writeJSONL([
            assistantEntry(id: "m1", outputTokens: 1, toolUses: [
                ("Bash", "tu1"),
                ("Read", "tu2"),
                ("Bash", "tu3"),
            ]),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.toolUseCounts["Bash"], 2)
        XCTAssertEqual(stats.toolUseCounts["Read"], 1)
    }

    func test_toolUseDedupByToolUseId() {
        // If the same tool_use id appears in two streaming chunks under
        // the same assistant message id, count once.
        let path = writeJSONL([
            assistantEntry(id: "m1", outputTokens: 1, toolUses: [("Bash", "tu1")]),
            assistantEntry(id: "m1", outputTokens: 1, toolUses: [("Bash", "tu1")]),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.toolUseCounts["Bash"], 1)
    }

    // MARK: - Last prompt / last output preview

    func test_lastPrompt_capturesUserText() {
        let path = writeJSONL([
            userEntry(text: "first prompt"),
            assistantEntry(id: "m1", outputTokens: 1),
            userEntry(text: "second prompt"),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.lastPrompt, "second prompt")
    }

    func test_lastPrompt_truncatesOver200Chars() {
        let long = String(repeating: "a", count: 250)
        let path = writeJSONL([userEntry(text: long)])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.lastPrompt?.count, 201, "truncated to 200 + ellipsis char")
        XCTAssertTrue(stats.lastPrompt?.hasSuffix("…") == true)
    }

    // MARK: - Time bounds

    func test_startEndTimesSpanAllEntries() {
        let path = writeJSONL([
            userEntry(text: "first", timestamp: "2026-04-25T08:00:00.000Z"),
            assistantEntry(id: "m1", timestamp: "2026-04-25T08:01:00.000Z", outputTokens: 1),
            userEntry(text: "later", timestamp: "2026-04-25T10:00:00.000Z"),
            assistantEntry(id: "m2", timestamp: "2026-04-25T10:05:00.000Z", outputTokens: 1),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertNotNil(stats.startTime)
        XCTAssertNotNil(stats.endTime)
        XCTAssertEqual(
            stats.endTime!.timeIntervalSince(stats.startTime!),
            7500,  // 2h 5m = 7500s
            accuracy: 1
        )
    }

    // MARK: - Context tokens

    func test_contextTokens_reflectsLastMessageInputAndCache() {
        // contextTokens = input + cache_creation + cache_read of the
        // most recent assistant message (live "what's loaded" indicator).
        let path = writeJSONL([
            assistantEntry(id: "m1", inputTokens: 100, cacheCreation: 0, cacheRead: 0),
            assistantEntry(id: "m2", inputTokens: 200, cacheCreation: 50, cacheRead: 1000),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.contextTokens, 1250)
    }

    // MARK: - 5-minute bucketing

    func test_fiveMinSlices_groupBy5MinuteBoundary() {
        let path = writeJSONL([
            assistantEntry(id: "m1", timestamp: "2026-04-25T10:00:00.000Z", outputTokens: 10),
            assistantEntry(id: "m2", timestamp: "2026-04-25T10:03:00.000Z", outputTokens: 10),
            assistantEntry(id: "m3", timestamp: "2026-04-25T10:06:00.000Z", outputTokens: 10),
        ])
        let stats = TranscriptParser.shared.parseSession(at: path)
        // First two messages share the [10:00, 10:05) slice; third is in
        // [10:05, 10:10).
        XCTAssertEqual(stats.fiveMinSlices.count, 2)
    }
}
