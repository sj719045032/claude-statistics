import XCTest

@testable import Claude_Statistics

/// Coverage for `CodexTranscriptParser.parseSession(at:)`. Codex's
/// session JSONL is a sequence of `{type, timestamp, payload}` records:
///   - `turn_context` — `payload.model` sets the active model.
///   - `response_item` — `payload.type` of `message` (with role
///     user/assistant) or `function_call` (tool invocations).
///   - `event_msg` — tokens flow in here as
///     `payload.type=token_count` → `payload.info.total_token_usage`.
///
/// Counts are derived from response_item; tokens come from event_msg
/// deltas (later snapshot - previous snapshot, so single events both
/// set & accumulate).
final class CodexTranscriptParserTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CodexTranscriptParserTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func writeJSONL(_ lines: [[String: Any]]) -> String {
        let path = tempDir.appendingPathComponent("session.jsonl").path
        let content = lines
            .map { try! String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func turnContext(model: String, timestamp: String = "2026-04-25T10:00:00.000Z") -> [String: Any] {
        ["type": "turn_context", "timestamp": timestamp, "payload": ["model": model]]
    }

    private func userMessage(_ text: String, timestamp: String = "2026-04-25T10:00:30.000Z") -> [String: Any] {
        [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["text": text]],
            ],
        ]
    }

    private func assistantMessage(_ text: String, timestamp: String = "2026-04-25T10:01:00.000Z") -> [String: Any] {
        [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["text": text]],
            ],
        ]
    }

    private func functionCall(name: String, args: String = "{}", timestamp: String = "2026-04-25T10:01:30.000Z") -> [String: Any] {
        [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": [
                "type": "function_call",
                "name": name,
                "arguments": args,
            ],
        ]
    }

    private func tokenCount(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        timestamp: String = "2026-04-25T10:02:00.000Z"
    ) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": inputTokens,
                        "output_tokens": outputTokens,
                        "cached_input_tokens": cachedInputTokens,
                    ],
                    "last_token_usage": [
                        "input_tokens": inputTokens,
                        "output_tokens": outputTokens,
                        "cached_input_tokens": cachedInputTokens,
                    ],
                ],
            ],
        ]
    }

    // MARK: - Empty / bad input

    func test_missingFile_returnsEmpty() {
        let stats = CodexTranscriptParser.shared.parseSession(at: "/nonexistent.jsonl")
        XCTAssertEqual(stats.userMessageCount, 0)
        XCTAssertEqual(stats.assistantMessageCount, 0)
    }

    func test_unknownTopLevelType_isSkipped() {
        let path = writeJSONL([
            ["type": "garbage_event", "timestamp": "2026-04-25T10:00:00.000Z", "payload": [:]],
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 0)
        XCTAssertEqual(stats.assistantMessageCount, 0)
    }

    // MARK: - Model from turn_context

    func test_turnContextSetsModel() {
        let path = writeJSONL([
            turnContext(model: "gpt-5"),
            assistantMessage("hi"),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.model, "gpt-5")
    }

    // MARK: - Counts

    func test_userAndAssistantCounts() {
        let path = writeJSONL([
            userMessage("hi"),
            assistantMessage("hello"),
            userMessage("again"),
            assistantMessage("ok"),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 2)
        XCTAssertEqual(stats.assistantMessageCount, 2)
    }

    // MARK: - Last prompt

    func test_lastPromptCapturesMostRecentUserText() {
        let path = writeJSONL([
            userMessage("first"),
            assistantMessage("ok"),
            userMessage("second"),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.lastPrompt, "second")
    }

    // MARK: - Time bounds

    func test_startEndTimes() {
        let path = writeJSONL([
            userMessage("a", timestamp: "2026-04-25T10:00:00.000Z"),
            assistantMessage("b", timestamp: "2026-04-25T10:30:00.000Z"),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertNotNil(stats.startTime)
        XCTAssertNotNil(stats.endTime)
        XCTAssertEqual(stats.endTime!.timeIntervalSince(stats.startTime!), 1800, accuracy: 1)
    }

    // MARK: - Tool tracking

    func test_functionCallSetsLastToolName() {
        let path = writeJSONL([
            assistantMessage("running"),
            functionCall(name: "exec_command", args: #"{"cmd": "ls"}"#),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertNotNil(stats.lastToolName)
        XCTAssertNotNil(stats.lastToolAt)
    }

    // MARK: - Token aggregation (delta-based)

    func test_tokenDeltaDrivesTotals() {
        // Codex sends cumulative token snapshots; the parser computes
        // deltas so two snapshots of (100, 50) and (300, 120) should
        // contribute exactly 300 input + 120 output to fiveMin slices
        // (the latest cumulative — the first becomes the baseline).
        let path = writeJSONL([
            tokenCount(inputTokens: 100, outputTokens: 50, timestamp: "2026-04-25T10:00:00.000Z"),
            tokenCount(inputTokens: 300, outputTokens: 120, timestamp: "2026-04-25T10:05:00.000Z"),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.totalInputTokens, 300)
        XCTAssertEqual(stats.totalOutputTokens, 120)
    }

    func test_singleTokenSnapshot_isFullyAttributed() {
        let path = writeJSONL([
            tokenCount(inputTokens: 100, outputTokens: 50),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.totalInputTokens, 100)
        XCTAssertEqual(stats.totalOutputTokens, 50)
    }

    func test_contextTokens_reflectsLastSnapshotInputPlusCache() {
        // UsageSnapshot derives inputTokens = rawInput - rawCached when no
        // total_tokens disambiguator is present (Codex's raw input_tokens
        // already includes the cached portion). Net contextTokens is just
        // rawInputTokens (= derived inputTokens + cachedInputTokens).
        let path = writeJSONL([
            tokenCount(inputTokens: 1000, outputTokens: 500, cachedInputTokens: 200),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.contextTokens, 1000)
    }

    // MARK: - 5-minute bucketing of tokens

    func test_tokensBucketedByFiveMinBoundary() {
        let path = writeJSONL([
            tokenCount(inputTokens: 100, outputTokens: 50, timestamp: "2026-04-25T10:00:00.000Z"),
            tokenCount(inputTokens: 200, outputTokens: 100, timestamp: "2026-04-25T10:03:00.000Z"),
            tokenCount(inputTokens: 400, outputTokens: 200, timestamp: "2026-04-25T10:07:00.000Z"),
        ])
        let stats = CodexTranscriptParser.shared.parseSession(at: path)
        // Token snapshots at 10:00 and 10:03 share [10:00, 10:05); 10:07 is in [10:05, 10:10).
        XCTAssertEqual(stats.fiveMinSlices.count, 2)
    }
}
