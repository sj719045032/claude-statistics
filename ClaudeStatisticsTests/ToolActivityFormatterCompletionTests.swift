import XCTest

@testable import Claude_Statistics

final class ToolActivityFormatterCompletionTests: XCTestCase {

    // MARK: - rawEventName gating

    func test_toolOutputSummary_preToolUseReturnsNil() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PreToolUse",
            toolName: "Read",
            input: ["file_path": .string("/foo/Bar.swift")],
            response: "anything",
            toolUseId: nil
        )
        XCTAssertNil(summary, "PreToolUse never produces a completion summary")
    }

    func test_toolOutputSummary_unknownEventReturnsNil() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "BeforeModel",
            toolName: "Read",
            input: ["file_path": .string("/foo/Bar.swift")],
            response: "anything",
            toolUseId: nil
        )
        XCTAssertNil(summary, "non-Post/Subagent events return nil")
    }

    func test_toolOutputSummary_postToolUseNilToolNoResponseReturnsNil() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: nil,
            input: nil,
            response: nil,
            toolUseId: nil
        )
        XCTAssertNil(summary, "no tool name + no response → no snippet to surface")
    }

    func test_toolOutputSummary_postToolUseFailureRoutesToCompletion() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUseFailure",
            toolName: "Bash",
            input: ["command": .string("xcodebuild -scheme MyApp build")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertNotNil(summary, "PostToolUseFailure routes to summarize path")
        XCTAssertEqual(summary?.kind, .echo, "no response → echo kind")
    }

    // MARK: - Read / Glob / WebSearch / WebFetch / TodoWrite / EnterPlanMode (echo kind)

    func test_toolOutputSummary_readEchoesFileBasename() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Read",
            input: ["file_path": .string("/Users/me/proj/Foo.swift")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo)
        XCTAssertTrue(summary?.text.contains("Foo.swift") ?? false, "echo text contains file basename")
    }

    func test_toolOutputSummary_globEcho() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Glob",
            input: ["pattern": .string("**/*.swift")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo, "glob is echo kind")
    }

    func test_toolOutputSummary_webSearchEcho() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "WebSearch",
            input: ["query": .string("swift testing")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo)
        XCTAssertTrue(summary?.text.contains("swift testing") ?? false)
    }

    func test_toolOutputSummary_todoWriteEcho() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "TodoWrite",
            input: [:],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo)
    }

    func test_toolOutputSummary_enterPlanModeEcho() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "ExitPlanMode",
            input: [:],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo)
    }

    // MARK: - Write / Edit / MultiEdit / Task (result kind)

    func test_toolOutputSummary_editIsResultKind() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Edit",
            input: ["file_path": .string("/foo.swift")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result, "Edit is treated as a completed result")
        XCTAssertTrue(summary?.text.contains("foo.swift") ?? false)
    }

    func test_toolOutputSummary_writeIsResultKind() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Write",
            input: ["file_path": .string("/foo.swift")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result)
    }

    func test_toolOutputSummary_taskIsResultKind() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Task",
            input: ["description": .string("review diff")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result)
    }

    // MARK: - Grep with response

    func test_toolOutputSummary_grepWithMultipleMatchesReportsCount() {
        let response = "src/a.swift:1:hit\nsrc/b.swift:2:hit\n"
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Grep",
            input: ["pattern": .string("foo")],
            response: response,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result, "grep with response routes through grepResultSummary")
        XCTAssertTrue(summary?.text.contains("foo") ?? false, "pattern is interpolated into the summary")
        XCTAssertTrue(summary?.text.contains("2") ?? false, "match count is interpolated")
    }

    func test_toolOutputSummary_grepWithSingleNonColonLineReturnsThatLine() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Grep",
            input: ["pattern": .string("foo")],
            response: "no matches found here",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result)
        XCTAssertEqual(summary?.text, "no matches found here", "single non-':' line is returned verbatim")
    }

    // MARK: - Grep without response

    func test_toolOutputSummary_grepWithoutResponseUsesEchoFromInput() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Grep",
            input: ["pattern": .string("foo")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo, "no response → echo from input")
        XCTAssertTrue(summary?.text.contains("foo") ?? false)
    }

    // MARK: - Bash branches

    func test_toolOutputSummary_bashWithCommandAndSuccessResponseIsResult() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Bash",
            input: ["command": .string("xcodebuild -scheme MyApp build")],
            response: "** BUILD SUCCEEDED **\nBuild succeeded",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result, "bash + success line → result")
        XCTAssertTrue(summary?.text.lowercased().contains("succeeded") ?? false)
    }

    func test_toolOutputSummary_bashWithCommandAndNeutralResponseFallsBackToEcho() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Bash",
            input: ["command": .string("xcodebuild -scheme MyApp build")],
            response: "Compiling FooModule\nLinking",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo, "no result-y line → echo of operation")
        XCTAssertTrue(summary?.text.contains("MyApp") ?? false, "operation summary mentions scheme")
    }

    func test_toolOutputSummary_bashWithCommandNoResponseEcho() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Bash",
            input: ["command": .string("xcodebuild -scheme MyApp build")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo)
        XCTAssertTrue(summary?.text.contains("Building MyApp") ?? false)
    }

    func test_toolOutputSummary_bashWithCommandAndFailureResponseIsResult() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Bash",
            input: ["command": .string("xcodebuild -scheme MyApp build")],
            response: "Compiling Foo\n** BUILD FAILED **\nBuild failed",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result, "build failed is also a result")
        XCTAssertTrue(summary?.text.lowercased().contains("failed") ?? false)
    }

    func test_toolOutputSummary_bashWithErrorResponseIsResult() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Bash",
            input: ["command": .string("git status")],
            response: "fatal\nerror: pathspec 'foo' did not match",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result)
        XCTAssertTrue(summary?.text.lowercased().contains("error:") ?? false)
    }

    func test_toolOutputSummary_bashDescriptionOnlyEcho() {
        // Command is unrecognised by shellCommandSummary, so the description
        // path should kick in.
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Bash",
            input: ["description": .string("Run helper")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo)
        XCTAssertTrue(summary?.text.contains("Run helper") ?? false)
    }

    func test_toolOutputSummary_bashDescriptionWithSuccessResponseIsResult() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Bash",
            input: ["description": .string("Run tests")],
            response: "All tests passed",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result)
        XCTAssertTrue(summary?.text.lowercased().contains("passed") ?? false)
    }

    // MARK: - Default branch (unknown tool)

    func test_toolOutputSummary_unknownToolWithResponseIsRawSnippet() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "MysteryTool",
            input: [:],
            response: "interesting output line",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .rawSnippet)
        XCTAssertEqual(summary?.text, "interesting output line")
    }

    func test_toolOutputSummary_unknownToolWithPlaceholderResponseIsNil() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "MysteryTool",
            input: [:],
            response: "json",
            toolUseId: nil
        )
        XCTAssertNil(summary, "placeholder snippet is rejected")
    }

    func test_toolOutputSummary_unknownToolWithoutResponseIsNil() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "MysteryTool",
            input: [:],
            response: nil,
            toolUseId: nil
        )
        XCTAssertNil(summary)
    }

    // MARK: - SubagentStop

    func test_toolOutputSummary_subagentStopWithToolUsesSummarize() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "SubagentStop",
            toolName: "Read",
            input: ["file_path": .string("/foo/Bar.swift")],
            response: nil,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .echo, "SubagentStop falls through summarize path first")
        XCTAssertTrue(summary?.text.contains("Bar.swift") ?? false)
    }

    func test_toolOutputSummary_subagentStopFallsBackToRawSnippet() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "SubagentStop",
            toolName: nil,
            input: nil,
            response: "agent said hello",
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .rawSnippet, "no tool → fallback raw snippet path")
        XCTAssertEqual(summary?.text, "agent said hello")
    }

    func test_toolOutputSummary_subagentStopPlaceholderResponseIsNil() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "SubagentStop",
            toolName: nil,
            input: nil,
            response: "stdout",
            toolUseId: nil
        )
        XCTAssertNil(summary, "placeholder snippet rejected even on SubagentStop")
    }

    func test_toolOutputSummary_subagentStopNoResponseNoToolIsNil() {
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "SubagentStop",
            toolName: nil,
            input: nil,
            response: nil,
            toolUseId: nil
        )
        XCTAssertNil(summary)
    }

    // MARK: - usefulResponseLines edges (via Grep path)

    func test_toolOutputSummary_grepFiltersAnsiAndMetadataLines() {
        // The first two lines should be filtered: an ANSI-only line and a
        // "Process group pgid:" metadata line. The third line is the only
        // useful one and contains no ':' → returned verbatim.
        let response = "\u{001B}[31m\u{001B}[0m\nProcess group pgid: 1\nrealmatch line"
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Grep",
            input: ["pattern": .string("x")],
            response: response,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.text, "realmatch line", "ANSI + metadata are filtered out")
    }

    func test_toolOutputSummary_grepFiltersPlaceholderLines() {
        // "json" placeholder is filtered; "src/a.swift:1:found" is the only
        // useful line. Single line containing ':' falls through to the count
        // branch (one match).
        let response = "json\nsrc/a.swift:1:found"
        let summary = ToolActivityFormatter.toolOutputSummary(
            rawEventName: "PostToolUse",
            toolName: "Grep",
            input: ["pattern": .string("found")],
            response: response,
            toolUseId: nil
        )
        XCTAssertEqual(summary?.kind, .result)
        XCTAssertTrue(summary?.text.contains("1") ?? false, "single useful match line counted as 1")
        XCTAssertTrue(summary?.text.contains("found") ?? false, "pattern interpolated")
    }
}
