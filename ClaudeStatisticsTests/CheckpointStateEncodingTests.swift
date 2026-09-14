import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// The Claude checkpoint state's compact binary encoding and the database's
/// checkpoint container must resume exactly like the JSON they replace, and
/// what earlier builds stored must still load.
final class CheckpointStateEncodingTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("session.jsonl") }
    private let stateMagic = Array("CCP2".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CheckpointEncoding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func assistant(_ id: String, tokens: Int, model: String = "claude-sonnet-4-6",
                           time: String, tool: String? = nil) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": "answer \(id)"]]
        if let tool { content.append(["type": "tool_use", "id": tool, "name": "Read", "input": ["file_path": "a.swift"]]) }
        return ["type": "assistant", "timestamp": time,
                "message": ["id": id, "model": model, "content": content,
                            "usage": ["input_tokens": tokens, "output_tokens": tokens / 2, "cache_read_input_tokens": 4]]]
    }

    private func user(_ text: String, time: String) -> [String: Any] {
        ["type": "user", "timestamp": time, "message": ["content": text]]
    }

    private func lines(_ entries: [[String: Any]]) throws -> Data {
        var data = Data()
        for entry in entries {
            data.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }

    private func append(_ entries: [[String: Any]]) throws {
        let handle = try FileHandle(forWritingTo: root)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try lines(entries))
    }

    private func parse(_ checkpoint: SessionParseCheckpoint?) throws -> CheckpointedSessionUpdate {
        try XCTUnwrap(ClaudeCheckpointParser.parse(at: root.path, checkpoint: checkpoint))
    }

    private func sorted<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func writeHistory() throws {
        try lines([user("question", time: "2026-09-01T10:00:00Z"),
                   assistant("a", tokens: 10, time: "2026-09-01T10:01:00Z", tool: "t1"),
                   assistant("b", tokens: 20, time: "2026-09-01T10:07:00Z")]).write(to: root)
    }

    /// A streaming revision of "a", a user turn, a new message on another model and a new tool.
    private func appendTurn() throws {
        try append([assistant("a", tokens: 40, time: "2026-09-01T10:01:00Z", tool: "t1"),
                    user("next", time: "2026-09-01T10:12:00Z"),
                    assistant("c", tokens: 30, model: "claude-opus-4-6", time: "2026-09-01T10:13:00Z", tool: "t2")])
    }

    func testStateRoundTripKeepsNilsEmptyStringsAndExactValues() throws {
        var state = ClaudeCheckpointParser.State()
        state.sources["/tmp/root.jsonl"] = .init(messages: [
            "m1": .init(model: nil, timestamp: nil, tokens: ModelTokenStats(inputTokens: 1, messageCount: 1)),
            "m2": .init(model: "", timestamp: Date(timeIntervalSinceReferenceDate: 12_345.678_901_234),
                        tokens: ModelTokenStats(inputTokens: .max, outputTokens: -1, cacheCreation5mTokens: 3,
                                                cacheCreation1hTokens: 4, cacheCreationTotalTokens: 5,
                                                cacheReadTokens: 6, messageCount: 1)),
            "é/🙂": .init(model: "claude-opus-4-6", timestamp: Date(timeIntervalSince1970: 0), tokens: ModelTokenStats()),
        ])
        state.sources["/tmp/root/subagents/child.jsonl"] = .init()
        state.main.seenAssistants = ["m1", "m2"]
        state.main.seenTools = ["tool-é"]
        state.main.customTitle = "Title"

        let encoded = try ClaudeCheckpointParser.encodeState(state)
        XCTAssertTrue(encoded.starts(with: stateMagic))
        let back = try ClaudeCheckpointParser.decodeState(encoded)
        XCTAssertEqual(try sorted(back.sources), try sorted(state.sources))
        XCTAssertEqual(back.main.seenAssistants, state.main.seenAssistants)
        XCTAssertEqual(back.main.seenTools, state.main.seenTools)
        XCTAssertEqual(back.main.customTitle, "Title")
        XCTAssertNil(back.main.slug)
        XCTAssertEqual(try sorted(back.stats), try sorted(state.stats))
    }

    func testBinaryAndLegacyJSONStatesResumeExactlyLikeAFullParse() throws {
        try writeHistory()
        let initial = try parse(nil)
        XCTAssertTrue(initial.checkpoint.state.starts(with: stateMagic))

        // The same state as an earlier build stored it: whole JSON.
        let legacyState = try JSONEncoder().encode(ClaudeCheckpointParser.decodeState(initial.checkpoint.state))
        let legacy = SessionParseCheckpoint(parserRevision: initial.checkpoint.parserRevision,
                                            sources: initial.checkpoint.sources, state: legacyState,
                                            id: initial.checkpoint.id)
        try appendTurn()

        let fromBinary = try parse(initial.checkpoint)
        let fromLegacy = try parse(legacy)
        let full = try parse(nil)
        XCTAssertEqual(try sorted(fromBinary.stats), try sorted(full.stats))
        XCTAssertEqual(try sorted(fromLegacy.stats), try sorted(full.stats))
        for resumed in [fromBinary, fromLegacy] {
            guard case .update = resumed.searchIndex else { return XCTFail("resumed, not rebuilt") }
        }
        XCTAssertTrue(fromLegacy.checkpoint.state.starts(with: stateMagic), "rewritten in the new layout")
    }

    func testAStateThatCannotBeReadFallsBackToAFullParse() throws {
        try writeHistory()
        let initial = try parse(nil)
        let truncated = SessionParseCheckpoint(parserRevision: initial.checkpoint.parserRevision,
                                               sources: initial.checkpoint.sources,
                                               state: initial.checkpoint.state.prefix(initial.checkpoint.state.count - 3),
                                               id: initial.checkpoint.id)
        XCTAssertThrowsError(try ClaudeCheckpointParser.decodeState(truncated.state))
        try appendTurn()

        let recovered = try parse(truncated)
        XCTAssertEqual(try sorted(recovered.stats), try sorted(parse(nil).stats))
        guard case .replaceIdentified = recovered.searchIndex else { return XCTFail("an unreadable state rebuilds") }
    }

    func testCheckpointContainerRoundTripsAndReadsEarlierRows() throws {
        try writeHistory()
        let checkpoint = try parse(nil).checkpoint

        let stored = try ParseCheckpointCoding.encode(checkpoint)
        XCTAssertTrue(stored.starts(with: Array("CSPC".utf8)))
        XCTAssertLessThan(stored.count, try JSONEncoder().encode(checkpoint).count, "state stored without base64")
        let back = try XCTUnwrap(ParseCheckpointCoding.decode(stored))
        XCTAssertEqual(back.id, checkpoint.id)
        XCTAssertEqual(back.parserRevision, checkpoint.parserRevision)
        XCTAssertEqual(back.state, checkpoint.state)
        XCTAssertEqual(try sorted(back.sources), try sorted(checkpoint.sources))
        XCTAssertEqual(ParseCheckpointCoding.decodeID(stored), checkpoint.id)

        // A row written by an earlier build: the whole checkpoint as JSON.
        let legacyRow = try JSONEncoder().encode(checkpoint)
        XCTAssertEqual(ParseCheckpointCoding.decode(legacyRow)?.state, checkpoint.state)
        XCTAssertEqual(ParseCheckpointCoding.decodeID(legacyRow), checkpoint.id)

        XCTAssertNil(ParseCheckpointCoding.decode(Data("CSPC".utf8) + Data([0xFF, 0xFF, 0, 0])))
        XCTAssertNil(ParseCheckpointCoding.decodeID(Data("not a checkpoint".utf8)))

        try appendTurn()
        XCTAssertEqual(try sorted(parse(back).stats), try sorted(parse(checkpoint).stats))
    }
}
