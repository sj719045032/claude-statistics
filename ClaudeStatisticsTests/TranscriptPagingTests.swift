import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// The paged transcript path must produce exactly the rows the whole-file
/// parse produces, while reading only the bytes a page cites.
final class TranscriptPagingTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("session.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    // MARK: - Fixtures

    private func user(_ text: String, time: String = "2026-09-01T10:00:00Z") -> [String: Any] {
        ["type": "user", "timestamp": time, "message": ["content": text]]
    }

    private func assistant(id: String?, text: String?, tools: [[String: Any]] = [],
                           results: [[String: Any]] = [],
                           time: String = "2026-09-01T10:01:00Z") -> [String: Any] {
        var content: [[String: Any]] = []
        if let text { content.append(["type": "text", "text": text]) }
        content.append(contentsOf: tools)
        content.append(contentsOf: results)
        var message: [String: Any] = ["content": content, "model": "claude-sonnet-4-6"]
        if let id { message["id"] = id }
        return ["type": "assistant", "timestamp": time, "message": message]
    }

    private func toolUse(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    private func toolResult(id: String, text: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": text]
    }

    private func write(_ entries: [[String: Any]], finalNewline: Bool = true) throws {
        var result = Data()
        for (index, entry) in entries.enumerated() {
            result.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            if finalNewline || index < entries.count - 1 { result.append(0x0A) }
        }
        try result.write(to: root)
    }

    /// Covers every cross-record rule the linker owns: streaming revision,
    /// tool result attachment, a call that carries its own detail, duplicate
    /// tool ids, a queued user message, and a skipped internal message.
    private func mixedTranscript() -> [[String: Any]] {
        [
            user("first question"),
            ["type": "queue-operation", "operation": "enqueue", "content": "queued question",
             "timestamp": "2026-09-01T10:00:30Z"],
            user("<system-reminder>internal</system-reminder>"),
            assistant(id: "m1", text: "partial"),
            assistant(id: "m1", text: "revised answer", time: "2026-09-01T10:02:00Z"),
            assistant(id: "m2", text: "calling tools", tools: [
                toolUse(id: "t1", name: "Read", input: ["file_path": "/tmp/a.swift"]),
                toolUse(id: "t2", name: "Bash", input: ["command": "echo one\necho two"]),
            ]),
            assistant(id: "m3", text: nil, results: [
                toolResult(id: "t1", text: "contents of a.swift"),
                toolResult(id: "t2", text: "one\ntwo"),
            ]),
            // Duplicate tool id — the first occurrence owns the row.
            assistant(id: "m4", text: nil, tools: [
                toolUse(id: "t1", name: "Read", input: ["file_path": "/tmp/ignored.swift"]),
            ]),
            user("last question"),
        ]
    }

    private func assertEqual(_ paged: [TranscriptDisplayMessage], _ whole: [TranscriptDisplayMessage],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(paged.count, whole.count, "row count", file: file, line: line)
        for (left, right) in zip(paged, whole) {
            XCTAssertEqual(left.id, right.id, file: file, line: line)
            XCTAssertEqual(left.role, right.role, "row \(left.id) role", file: file, line: line)
            XCTAssertEqual(left.text, right.text, "row \(left.id) text", file: file, line: line)
            XCTAssertEqual(left.toolName, right.toolName, "row \(left.id) tool", file: file, line: line)
            XCTAssertEqual(left.toolDetail, right.toolDetail, "row \(left.id) detail", file: file, line: line)
            XCTAssertEqual(left.editOldString, right.editOldString, "row \(left.id) old", file: file, line: line)
            XCTAssertEqual(left.editNewString, right.editNewString, "row \(left.id) new", file: file, line: line)
            XCTAssertEqual(left.timestamp, right.timestamp, "row \(left.id) time", file: file, line: line)
        }
    }

    // MARK: - Equivalence

    func testOutlinePlusPagesEqualsWholeFileParse() throws {
        try write(mixedTranscript())
        let parser = TranscriptParser.shared
        let whole = parser.parseMessages(at: root.path)
        let outline = try parser.loadTranscriptOutline(at: root.path)

        XCTAssertEqual(outline.entries.map(\.id), whole.map(\.id))
        XCTAssertEqual(outline.entries.map(\.role), whole.map(\.role))
        XCTAssertEqual(outline.entries.map(\.toolName), whole.map(\.toolName))
        XCTAssertTrue(outline.matchesSources())

        let paged = try parser.loadTranscriptPage(at: root.path, entries: outline.entries)
        assertEqual(paged, whole)
    }

    func testArbitraryPageWindowsEqualTheSameSliceOfTheWholeParse() throws {
        try write(mixedTranscript())
        let parser = TranscriptParser.shared
        let whole = parser.parseMessages(at: root.path)
        let entries = try parser.loadTranscriptOutline(at: root.path).entries

        for size in [1, 2, 3, 5] {
            var collected: [TranscriptDisplayMessage] = []
            for start in stride(from: 0, to: entries.count, by: size) {
                let slice = Array(entries[start..<min(start + size, entries.count)])
                collected += try parser.loadTranscriptPage(at: root.path, entries: slice)
            }
            assertEqual(collected, whole)
        }
    }

    func testEditToolRowKeepsDiffStringsAndOwnDetailWins() throws {
        try write([
            assistant(id: "m1", text: nil, tools: [
                toolUse(id: "e1", name: "Edit", input: [
                    "file_path": "/tmp/x.swift", "old_string": "before", "new_string": "after",
                ]),
                toolUse(id: "w1", name: "Write", input: [
                    "file_path": "/tmp/y.swift", "content": "written body",
                ]),
            ]),
            assistant(id: "m2", text: nil, tools: [
                toolUse(id: "e2", name: "Edit", input: [
                    "file_path": "/tmp/z.swift", "old_string": "kept old", "new_string": "kept new",
                ]),
            ]),
            assistant(id: "m3", text: nil, results: [
                toolResult(id: "e1", text: "edit applied"),
                toolResult(id: "w1", text: "write applied"),
            ]),
        ])
        let parser = TranscriptParser.shared
        let whole = parser.parseMessages(at: root.path)
        let entries = try parser.loadTranscriptOutline(at: root.path).entries
        assertEqual(try parser.loadTranscriptPage(at: root.path, entries: entries), whole)

        // Edit carries no detail of its own, so it shows its result; Write's
        // content is its detail and the result must not overwrite it.
        XCTAssertEqual(whole.first(where: { $0.id == "tool-e1" })?.toolDetail, "edit applied")
        XCTAssertEqual(whole.first(where: { $0.id == "tool-w1" })?.toolDetail, "written body")
        // A row that receives a tool result is rebuilt without its diff
        // strings. That is long-standing display behavior, not something this
        // change introduces — both paths must agree on it.
        XCTAssertNil(whole.first(where: { $0.id == "tool-e1" })?.editOldString)
        // A row that keeps its own detail keeps its diff strings.
        XCTAssertEqual(whole.first(where: { $0.id == "tool-w1" })?.editOldString, nil)
        // An Edit row with no result keeps both diff strings on both paths.
        XCTAssertEqual(whole.first(where: { $0.id == "tool-e2" })?.editOldString, "kept old")
        XCTAssertEqual(whole.first(where: { $0.id == "tool-e2" })?.editNewString, "kept new")
    }

    func testFinalRecordWithoutNewlineIsIncluded() throws {
        try write(mixedTranscript(), finalNewline: false)
        let parser = TranscriptParser.shared
        let whole = parser.parseMessages(at: root.path)
        let entries = try parser.loadTranscriptOutline(at: root.path).entries
        XCTAssertEqual(entries.map(\.id), whole.map(\.id))
        assertEqual(try parser.loadTranscriptPage(at: root.path, entries: entries), whole)
    }

    func testToolUseWithoutIdGetsAPositionalRowIdBothPathsAgreeOn() throws {
        try write([
            assistant(id: "m1", text: nil, tools: [
                ["type": "tool_use", "name": "Glob", "input": ["pattern": "*.swift"]],
            ]),
        ])
        let parser = TranscriptParser.shared
        let whole = parser.parseMessages(at: root.path)
        let entries = try parser.loadTranscriptOutline(at: root.path).entries
        XCTAssertEqual(whole.count, 1)
        XCTAssertEqual(entries.map(\.id), whole.map(\.id))
        assertEqual(try parser.loadTranscriptPage(at: root.path, entries: entries), whole)
    }

    // MARK: - Bounded reads

    func testPageReadsOnlyTheBytesItCites() throws {
        // One small conversation buried in a large history.
        var entries: [[String: Any]] = []
        let filler = String(repeating: "x", count: 4_000)
        for index in 0..<400 {
            entries.append(user("filler \(index) \(filler)"))
        }
        entries.append(assistant(id: "tail", text: "the tail answer"))
        try write(entries)

        let parser = TranscriptParser.shared
        let outline = try parser.loadTranscriptOutline(at: root.path)
        let fileSize = try TranscriptFileSnapshot.read(at: root.path).size
        XCTAssertGreaterThan(fileSize, 1_500_000)

        let last = Array(outline.entries.suffix(1))
        let cited = last.reduce(Int64(0)) { $0 + $1.locator.byteCount }
        XCTAssertLessThan(cited, 4_000, "one row must not cite the history")

        let page = try parser.loadTranscriptPage(at: root.path, entries: last)
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page[0].text, "the tail answer")
    }

    func testOutlineStateIsSmallRelativeToTheTranscript() throws {
        var entries: [[String: Any]] = []
        let filler = String(repeating: "y", count: 4_000)
        for index in 0..<400 { entries.append(user("filler \(index) \(filler)")) }
        try write(entries)

        let outline = try TranscriptParser.shared.loadTranscriptOutline(at: root.path)
        let fileSize = try TranscriptFileSnapshot.read(at: root.path).size
        let outlineBytes = outline.entries.reduce(0) {
            $0 + $1.id.utf8.count + $1.role.utf8.count + ($1.toolName?.utf8.count ?? 0)
                + $1.locator.source.utf8.count + $1.locator.ranges.count * 16 + 48
        }
        XCTAssertEqual(outline.entries.count, 400)
        XCTAssertLessThan(Int64(outlineBytes) * 20, fileSize,
                          "outline must be far smaller than the transcript it indexes")
    }

    /// An actively written transcript is only ever appended to. Its outline
    /// must stay valid — otherwise every page after an append would rebuild it.
    func testAppendedSourceKeepsTheOutlineAndItsPagesValid() throws {
        try write(mixedTranscript())
        let parser = TranscriptParser.shared
        let outline = try parser.loadTranscriptOutline(at: root.path)
        let before = try parser.loadTranscriptPage(at: root.path, entries: outline.entries)

        let handle = try FileHandle(forWritingTo: root)
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: user("appended later")))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        XCTAssertTrue(outline.matchesSources(), "an append leaves every recorded range valid")
        assertEqual(try parser.loadTranscriptPage(at: root.path, entries: outline.entries), before)
    }

    func testReplacedSourceIsDetectedAndStalePageIsNotFaked() throws {
        try write(mixedTranscript())
        let parser = TranscriptParser.shared
        let outline = try parser.loadTranscriptOutline(at: root.path)
        XCTAssertTrue(outline.matchesSources())

        try write([user("completely different")])
        XCTAssertFalse(outline.matchesSources())

        // Ranges past the new EOF yield no row rather than a wrong one.
        let page = try parser.loadTranscriptPage(at: root.path, entries: outline.entries)
        XCTAssertLessThan(page.count, outline.entries.count)
    }
}
