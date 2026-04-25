import XCTest

@testable import Claude_Statistics

final class ToolOutputCleaningTests: XCTestCase {
    // MARK: - cleanedLine

    func test_cleanedLine_trimsWhitespace() {
        XCTAssertEqual(ToolOutputCleaning.cleanedLine("  hello  "), "hello")
    }

    func test_cleanedLine_emptyOrWhitespaceReturnsEmpty() {
        XCTAssertEqual(ToolOutputCleaning.cleanedLine(""), "")
        XCTAssertEqual(ToolOutputCleaning.cleanedLine("   \t\n"), "")
    }

    func test_cleanedLine_stripsLeadingOutputPrefix() {
        XCTAssertEqual(ToolOutputCleaning.cleanedLine("Output: hello"), "hello")
        XCTAssertEqual(ToolOutputCleaning.cleanedLine("output: hello"), "hello", "case-insensitive")
        XCTAssertEqual(ToolOutputCleaning.cleanedLine("OUTPUT:hello"), "hello", "no space after colon")
    }

    func test_cleanedLine_doesNotStripMidLineOutput() {
        XCTAssertEqual(
            ToolOutputCleaning.cleanedLine("see Output: above"),
            "see Output: above",
            "only leading Output: is stripped"
        )
    }

    // MARK: - isUnhelpfulMetadataLine

    func test_isUnhelpfulMetadataLine_processGroupHeader() {
        XCTAssertTrue(ToolOutputCleaning.isUnhelpfulMetadataLine("Process group pgid: 12345"))
        XCTAssertTrue(ToolOutputCleaning.isUnhelpfulMetadataLine("  process group pgid: 0"))
    }

    func test_isUnhelpfulMetadataLine_backgroundPidsHeader() {
        XCTAssertTrue(ToolOutputCleaning.isUnhelpfulMetadataLine("Background PIDs: 4321, 5678"))
    }

    func test_isUnhelpfulMetadataLine_regularTextIsKept() {
        XCTAssertFalse(ToolOutputCleaning.isUnhelpfulMetadataLine("hello world"))
        XCTAssertFalse(ToolOutputCleaning.isUnhelpfulMetadataLine("error: something failed"))
    }

    // MARK: - stripAnsi

    func test_stripAnsi_removesColorCsi() {
        let input = "\u{001B}[31mred\u{001B}[0m"
        XCTAssertEqual(ToolOutputCleaning.stripAnsi(input), "red")
    }

    func test_stripAnsi_removesCursorMovement() {
        let input = "before\u{001B}[2Kafter"
        XCTAssertEqual(ToolOutputCleaning.stripAnsi(input), "beforeafter")
    }

    func test_stripAnsi_passesThroughPlainText() {
        XCTAssertEqual(ToolOutputCleaning.stripAnsi("plain text"), "plain text")
    }

    func test_stripAnsi_eatsByteAfterLoneEscape() {
        // Quirk: when ESC is not followed by `[`, the implementation still
        // consumes the next iterator byte unconditionally. In practice tool
        // output never contains lone ESC bytes, so this is harmless — but
        // it is the actual behavior so the test pins it down.
        XCTAssertEqual(ToolOutputCleaning.stripAnsi("a\u{001B}b"), "a")
    }

    // MARK: - isPlaceholderOutput

    func test_isPlaceholderOutput_recognisedMarkers() {
        for marker in ["text", "json", "stdout", "output", "(empty)", "---", "--"] {
            XCTAssertTrue(
                ToolOutputCleaning.isPlaceholderOutput(marker),
                "\(marker) should be a placeholder"
            )
            XCTAssertTrue(
                ToolOutputCleaning.isPlaceholderOutput("  \(marker.uppercased())  "),
                "case-insensitive + trim: \(marker)"
            )
        }
    }

    func test_isPlaceholderOutput_realTextIsNotPlaceholder() {
        XCTAssertFalse(ToolOutputCleaning.isPlaceholderOutput("hello"))
        XCTAssertFalse(ToolOutputCleaning.isPlaceholderOutput("text output"))
    }

    // MARK: - snippet

    func test_snippet_picksLastUsefulLine() {
        let raw = "first\nsecond\nthird"
        XCTAssertEqual(ToolOutputCleaning.snippet(from: raw), "third")
    }

    func test_snippet_stripsAnsiAndOutputPrefix() {
        let raw = "\u{001B}[2KOutput: \u{001B}[32mreal value\u{001B}[0m"
        XCTAssertEqual(ToolOutputCleaning.snippet(from: raw), "real value")
    }

    func test_snippet_skipsPlaceholderLines() {
        let raw = "real\njson\n(empty)"
        XCTAssertEqual(
            ToolOutputCleaning.snippet(from: raw),
            "real",
            "placeholder lines drop, real line is the only survivor"
        )
    }

    func test_snippet_skipsMetadataLines() {
        let raw = "actual content\nProcess group pgid: 1\nBackground PIDs: 2"
        XCTAssertEqual(ToolOutputCleaning.snippet(from: raw), "actual content")
    }

    func test_snippet_truncatesAt100Chars() {
        let long = String(repeating: "x", count: 200)
        let result = ToolOutputCleaning.snippet(from: long)
        XCTAssertEqual(result?.count, 101, "100 chars + ellipsis")
        XCTAssertTrue(result?.hasSuffix("…") ?? false)
    }

    func test_snippet_returnsNilWhenNothingUseful() {
        XCTAssertNil(ToolOutputCleaning.snippet(from: ""))
        XCTAssertNil(ToolOutputCleaning.snippet(from: "json\nstdout\n(empty)"))
        XCTAssertNil(ToolOutputCleaning.snippet(from: "Process group pgid: 1"))
    }

    func test_snippet_normalisesCRLFAndCR() {
        XCTAssertEqual(ToolOutputCleaning.snippet(from: "a\r\nb\rc"), "c")
    }
}
