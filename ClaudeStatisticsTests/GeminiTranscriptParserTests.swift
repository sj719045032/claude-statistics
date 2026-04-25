import XCTest

@testable import Claude_Statistics

/// Coverage for `GeminiTranscriptParser.parseSession(at:)`. Gemini's
/// transcript is a single JSON object (NOT JSONL):
///
///     { "sessionId": "...", "startTime": "...", "lastUpdated": "...",
///       "summary": "...",
///       "messages": [{ "type": "user"|"gemini", "timestamp": "...",
///                      "content": "..." or [{text: "..."}],
///                      "tokens": {...}, "model": "...",
///                      "toolCalls": [...] }, ...] }
///
/// Tokens parsing has a normalization step: when total = rawInput +
/// billedOutput, rawInput is treated as already including cached, so
/// `inputTokens` becomes rawInput - cached. With no total provided,
/// we conservatively assume inputIncludesCached=true.
final class GeminiTranscriptParserTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GeminiTranscriptParserTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func writeTranscript(_ root: [String: Any]) -> String {
        let path = tempDir.appendingPathComponent("session.json").path
        let data = try! JSONSerialization.data(withJSONObject: root)
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func userMessage(_ text: String, timestamp: String = "2026-04-25T10:00:00.000Z", id: String? = nil) -> [String: Any] {
        var msg: [String: Any] = [
            "type": "user",
            "timestamp": timestamp,
            "content": text,
        ]
        if let id { msg["id"] = id }
        return msg
    }

    private func geminiMessage(
        _ text: String,
        timestamp: String = "2026-04-25T10:01:00.000Z",
        model: String? = nil,
        tokens: [String: Any]? = nil,
        toolCalls: [[String: Any]]? = nil
    ) -> [String: Any] {
        var msg: [String: Any] = [
            "type": "gemini",
            "timestamp": timestamp,
            "content": text,
        ]
        if let model { msg["model"] = model }
        if let tokens { msg["tokens"] = tokens }
        if let toolCalls { msg["toolCalls"] = toolCalls }
        return msg
    }

    // MARK: - Empty / bad input

    func test_missingFile_returnsEmpty() {
        let stats = GeminiTranscriptParser.shared.parseSession(at: "/nonexistent.json")
        XCTAssertEqual(stats.userMessageCount, 0)
        XCTAssertEqual(stats.assistantMessageCount, 0)
    }

    func test_invalidJSON_returnsEmpty() {
        let path = tempDir.appendingPathComponent("bad.json").path
        try? "not json at all".write(toFile: path, atomically: true, encoding: .utf8)
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 0)
    }

    func test_emptyMessages() {
        let path = writeTranscript(["messages": []])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 0)
        XCTAssertEqual(stats.assistantMessageCount, 0)
    }

    // MARK: - Counts

    func test_userAndAssistantCounts() {
        let path = writeTranscript([
            "messages": [
                userMessage("hi"),
                geminiMessage("hello"),
                userMessage("again"),
                geminiMessage("ok"),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 2)
        XCTAssertEqual(stats.assistantMessageCount, 2)
    }

    // MARK: - Model

    func test_model_takesLatestGeminiMessage() {
        let path = writeTranscript([
            "messages": [
                geminiMessage("first", model: "gemini-pro"),
                geminiMessage("second", model: "gemini-flash"),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.model, "gemini-flash")
    }

    // MARK: - Last prompt

    func test_lastPromptCapturesMostRecentUser() {
        let path = writeTranscript([
            "messages": [
                userMessage("first"),
                geminiMessage("ok"),
                userMessage("second"),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.lastPrompt, "second")
    }

    // MARK: - Time bounds (root + per-message)

    func test_rootStartLastUpdated() {
        let path = writeTranscript([
            "startTime": "2026-04-25T08:00:00.000Z",
            "lastUpdated": "2026-04-25T09:30:00.000Z",
            "messages": [
                geminiMessage("x", timestamp: "2026-04-25T08:30:00.000Z", model: "gemini-pro"),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertNotNil(stats.startTime)
        XCTAssertNotNil(stats.endTime)
        XCTAssertEqual(stats.endTime!.timeIntervalSince(stats.startTime!), 5400, accuracy: 1)
    }

    // MARK: - Tokens

    func test_tokensSumAcrossGeminiMessages() {
        let path = writeTranscript([
            "messages": [
                geminiMessage(
                    "x",
                    timestamp: "2026-04-25T10:00:00.000Z",
                    model: "gemini-pro",
                    tokens: ["input": 100, "output": 50]
                ),
                geminiMessage(
                    "y",
                    timestamp: "2026-04-25T10:01:00.000Z",
                    model: "gemini-pro",
                    tokens: ["input": 200, "output": 80]
                ),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        // input is treated as already including cached when no total —
        // cached defaults to 0, so derived inputTokens = raw input.
        XCTAssertEqual(stats.totalInputTokens, 300)
        XCTAssertEqual(stats.totalOutputTokens, 130)
    }

    func test_tokens_cachedSplit_whenTotalProvided() {
        // total = rawInput + billedOutput → parser infers input includes
        // cached, so derived inputTokens = rawInput - cachedTokens.
        let path = writeTranscript([
            "messages": [
                geminiMessage(
                    "x",
                    timestamp: "2026-04-25T10:00:00.000Z",
                    model: "gemini-pro",
                    tokens: [
                        "input": 1000,
                        "output": 500,
                        "cached": 200,
                        "total": 1500,
                    ]
                ),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.totalInputTokens, 800)  // 1000 - 200
        XCTAssertEqual(stats.totalOutputTokens, 500)
        XCTAssertEqual(stats.cacheReadTokens, 200)
    }

    // MARK: - Tool calls

    func test_toolCallsAppearInToolUseCounts() {
        let path = writeTranscript([
            "messages": [
                geminiMessage(
                    "running shell",
                    timestamp: "2026-04-25T10:00:00.000Z",
                    toolCalls: [
                        ["id": "t1", "name": "run_shell_command"],
                        ["id": "t2", "name": "read_file"],
                    ]
                ),
                geminiMessage(
                    "more",
                    timestamp: "2026-04-25T10:01:00.000Z",
                    toolCalls: [["id": "t3", "name": "run_shell_command"]]
                ),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        // Both tool calls in the same message land in the same fiveMin
        // slice; the second message also lands there since it's < 5min
        // later. Aggregate across slices via toolUseCounts.
        let bashCount = stats.toolUseCounts.filter { $0.key.localizedCaseInsensitiveContains("bash") || $0.key.localizedCaseInsensitiveContains("shell") }.values.reduce(0, +)
        XCTAssertEqual(bashCount, 2, "two shell commands across two messages")
    }

    func test_lastToolNameSetFromTrailingToolCall() {
        let path = writeTranscript([
            "messages": [
                geminiMessage(
                    "x",
                    timestamp: "2026-04-25T10:00:00.000Z",
                    toolCalls: [["id": "tc1", "name": "read_file"]]
                ),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertNotNil(stats.lastToolName)
        XCTAssertNotNil(stats.lastToolAt)
    }

    // MARK: - 5-minute bucketing

    func test_fiveMinSlicesBucketing() {
        let path = writeTranscript([
            "messages": [
                geminiMessage(
                    "a",
                    timestamp: "2026-04-25T10:00:00.000Z",
                    model: "gemini-pro",
                    tokens: ["input": 50, "output": 20]
                ),
                geminiMessage(
                    "b",
                    timestamp: "2026-04-25T10:03:00.000Z",
                    model: "gemini-pro",
                    tokens: ["input": 80, "output": 30]
                ),
                geminiMessage(
                    "c",
                    timestamp: "2026-04-25T10:07:00.000Z",
                    model: "gemini-pro",
                    tokens: ["input": 120, "output": 50]
                ),
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.fiveMinSlices.count, 2, "10:00 + 10:03 share one slice; 10:07 is its own")
    }

    // MARK: - Content arrays

    func test_contentArrayWithTextItems_isExtracted() {
        // User content can be a `[{text: "..."}]` array (legacy shape).
        // cleanUserText keeps only the first non-empty line, so the
        // second item gets trimmed off — verify the first one survives.
        let path = writeTranscript([
            "messages": [
                [
                    "type": "user",
                    "timestamp": "2026-04-25T10:00:00.000Z",
                    "content": [["text": "hello"], ["text": "world"]],
                ],
            ],
        ])
        let stats = GeminiTranscriptParser.shared.parseSession(at: path)
        XCTAssertEqual(stats.userMessageCount, 1)
        XCTAssertEqual(stats.lastPrompt, "hello")
    }
}
