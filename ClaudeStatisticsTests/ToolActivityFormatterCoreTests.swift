import Foundation
import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

final class ToolActivityFormatterCoreTests: XCTestCase {

    // MARK: - Helpers

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        GeminiTestPlaceholder.register()
    }

    override func tearDown() {
        GeminiTestPlaceholder.unregister()
        super.tearDown()
    }

    // MARK: - canonicalToolName

    func test_canonicalToolName_nilReturnsEmpty() {
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName(nil), "")
    }

    func test_canonicalToolName_emptyReturnsEmpty() {
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName(""), "")
    }

    func test_canonicalToolName_whitespaceOnlyReturnsEmpty() {
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName("   "), "")
    }

    func test_canonicalToolName_lowercasesPascalCase() {
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName("Edit"), "edit")
    }

    func test_canonicalToolName_passThroughLowercase() {
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName("edit"), "edit")
    }

    func test_canonicalToolName_codexAliasResolves() {
        // CodexToolNames maps `apply_patch` → `edit`. The provider-agnostic
        // resolver should still find it since it tries every provider's table.
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName("apply_patch"), "edit")
    }

    func test_canonicalToolName_geminiAliasResolves() {
        // GeminiToolNames maps `run_shell_command` → `bash`.
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName("run_shell_command"), "bash")
    }

    func test_canonicalToolName_unknownPassesThroughLowercased() {
        XCTAssertEqual(ToolActivityFormatter.canonicalToolName("MyCustomTool"), "mycustomtool")
    }

    // MARK: - currentOperation: PreToolUse

    func test_currentOperation_preToolUseWithToolReturnsToolKind() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "PreToolUse",
            toolName: "Read",
            input: ["file_path": .string("/foo/Bar.swift")],
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: "tu_1"
        )
        XCTAssertNotNil(op)
        XCTAssertEqual(op?.kind, .tool)
        XCTAssertEqual(op?.toolName, "Read")
        XCTAssertEqual(op?.toolUseId, "tu_1")
        XCTAssertEqual(op?.symbol, "doc.text")
        XCTAssertEqual(op?.startedAt, fixedDate)
        // running text should reference the file basename in some form.
        XCTAssertTrue(op?.text.contains("Bar.swift") ?? false,
                      "expected basename in running text, got: \(op?.text ?? "nil")")
    }

    func test_currentOperation_preToolUseNoToolFallbackClaudeThinking() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "PreToolUse",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertNotNil(op)
        XCTAssertEqual(op?.kind, .tool)
        // Claude fallback uses the localized "Thinking..." string.
        XCTAssertTrue(op?.text.lowercased().contains("think") ?? false,
                      "expected Claude fallback to mention 'Thinking', got: \(op?.text ?? "nil")")
    }

    func test_currentOperation_preToolUseNoToolFallbackCodexWorking() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "PreToolUse",
            toolName: nil,
            input: nil,
            provider: .codex,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertNotNil(op)
        XCTAssertEqual(op?.kind, .tool)
        // Codex/Gemini fallback uses the localized "Working..." string.
        XCTAssertTrue(op?.text.lowercased().contains("work") ?? false,
                      "expected Codex fallback to mention 'Working', got: \(op?.text ?? "nil")")
    }

    func test_currentOperation_preToolUseNoToolFallbackGeminiWorking() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "PreToolUse",
            toolName: nil,
            input: nil,
            provider: .gemini,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertTrue(op?.text.lowercased().contains("work") ?? false,
                      "expected Gemini fallback to mention 'Working', got: \(op?.text ?? "nil")")
    }

    // MARK: - currentOperation: SubagentStart

    func test_currentOperation_subagentStartNamedReturnsSubagentKind() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "SubagentStart",
            toolName: "Reviewer",
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: "sub_1"
        )
        XCTAssertEqual(op?.kind, .subagent)
        XCTAssertEqual(op?.symbol, "wand.and.stars")
        XCTAssertEqual(op?.toolName, "Reviewer")
        XCTAssertTrue(op?.text.contains("Reviewer") ?? false,
                      "expected subagent name in text, got: \(op?.text ?? "nil")")
    }

    func test_currentOperation_subagentStartUnnamedFallback() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "SubagentStart",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertEqual(op?.kind, .subagent)
        XCTAssertEqual(op?.symbol, "wand.and.stars")
        XCTAssertNil(op?.toolName)
        // Default subagent text mentions "subagent".
        XCTAssertTrue(op?.text.lowercased().contains("subagent") ?? false,
                      "expected default subagent text, got: \(op?.text ?? "nil")")
    }

    // MARK: - currentOperation: BeforeToolSelection

    func test_currentOperation_beforeToolSelection() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "BeforeToolSelection",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertEqual(op?.kind, .toolSelection)
        XCTAssertEqual(op?.symbol, "slider.horizontal.3")
        XCTAssertNil(op?.toolName)
    }

    // MARK: - currentOperation: BeforeModel

    func test_currentOperation_beforeModelClaude() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "BeforeModel",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertEqual(op?.kind, .modelThinking)
        XCTAssertEqual(op?.symbol, "sparkles")
        XCTAssertTrue(op?.text.lowercased().contains("think") ?? false)
    }

    // MARK: - currentOperation: PreCompress / PreCompact

    func test_currentOperation_preCompress() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "PreCompress",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertEqual(op?.kind, .compressing)
    }

    func test_currentOperation_preCompact() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "PreCompact",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertEqual(op?.kind, .compacting)
    }

    // MARK: - currentOperation: UserPromptSubmit / SessionStart

    func test_currentOperation_userPromptSubmit() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "UserPromptSubmit",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertEqual(op?.kind, .genericProcessing)
        XCTAssertEqual(op?.symbol, "sparkles")
    }

    func test_currentOperation_sessionStart() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "SessionStart",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertEqual(op?.kind, .genericProcessing)
        XCTAssertEqual(op?.symbol, "play.circle")
    }

    // MARK: - currentOperation: unknown / non-mapped

    func test_currentOperation_postToolUseReturnsNil() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "PostToolUse",
            toolName: "Read",
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertNil(op, "PostToolUse should not produce a current operation here")
    }

    func test_currentOperation_unknownEventReturnsNil() {
        let op = ToolActivityFormatter.currentOperation(
            rawEventName: "TotallyMadeUpEvent",
            toolName: nil,
            input: nil,
            provider: .claude,
            receivedAt: fixedDate,
            toolUseId: nil
        )
        XCTAssertNil(op)
    }

    // MARK: - liveSummary

    func test_liveSummary_permissionRequestAlwaysNil() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "PermissionRequest",
            notificationType: nil,
            toolName: "Bash",
            input: ["command": .string("ls")],
            provider: .claude
        )
        XCTAssertNil(summary, "PermissionRequest must not overwrite the running activity text")
    }

    func test_liveSummary_toolPermissionWithToolReturnsRunningSummary() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "ToolPermission",
            notificationType: nil,
            toolName: "Bash",
            input: ["command": .string("ls -la")],
            provider: .claude
        )
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.lowercased().contains("bash") ?? summary?.contains("ls") ?? false,
                      "expected runningSummary output for Bash, got: \(summary ?? "nil")")
    }

    func test_liveSummary_toolPermissionMissingToolFallback() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "ToolPermission",
            notificationType: nil,
            toolName: nil,
            input: nil,
            provider: .claude
        )
        XCTAssertEqual(summary?.lowercased().contains("think"), true,
                       "expected Claude fallback when no tool name, got: \(summary ?? "nil")")
    }

    func test_liveSummary_preToolUseWithToolUsesRunningSummary() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "PreToolUse",
            notificationType: nil,
            toolName: "Read",
            input: ["file_path": .string("/Users/me/x/Foo.swift")],
            provider: .claude
        )
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("Foo.swift") ?? false,
                      "expected file basename in summary, got: \(summary ?? "nil")")
    }

    func test_liveSummary_preToolUseNoToolFallback() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "PreToolUse",
            notificationType: nil,
            toolName: nil,
            input: nil,
            provider: .codex
        )
        XCTAssertTrue(summary?.lowercased().contains("work") ?? false,
                      "expected Codex 'working' fallback, got: \(summary ?? "nil")")
    }

    func test_liveSummary_userPromptSubmitReturnsFallback() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "UserPromptSubmit",
            notificationType: nil,
            toolName: nil,
            input: nil,
            provider: .claude
        )
        XCTAssertTrue(summary?.lowercased().contains("think") ?? false)
    }

    func test_liveSummary_subagentStartNamed() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "SubagentStart",
            notificationType: nil,
            toolName: "Reviewer",
            input: nil,
            provider: .claude
        )
        XCTAssertTrue(summary?.contains("Reviewer") ?? false,
                      "expected subagent name, got: \(summary ?? "nil")")
    }

    func test_liveSummary_beforeToolSelection() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "BeforeToolSelection",
            notificationType: nil,
            toolName: nil,
            input: nil,
            provider: .claude
        )
        XCTAssertTrue(summary?.lowercased().contains("tool") ?? false)
    }

    func test_liveSummary_postToolUseReturnsFallback() {
        // PostToolUse transitions back to a generic processing label so the
        // notch keeps a visible status between tool calls. Should be a
        // non-empty fallback, not nil.
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "PostToolUse",
            notificationType: nil,
            toolName: "Read",
            input: nil,
            provider: .claude
        )
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary?.isEmpty ?? true)
    }

    func test_liveSummary_notificationReturnsNil() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "Notification",
            notificationType: "permission_prompt",
            toolName: nil,
            input: nil,
            provider: .claude
        )
        XCTAssertNil(summary)
    }

    func test_liveSummary_sessionStart() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "SessionStart",
            notificationType: nil,
            toolName: nil,
            input: nil,
            provider: .claude
        )
        XCTAssertTrue(summary?.lowercased().contains("start") ?? false)
    }

    func test_liveSummary_unknownEventReturnsNil() {
        let summary = ToolActivityFormatter.liveSummary(
            rawEventName: "TotallyUnknown",
            notificationType: nil,
            toolName: "Read",
            input: nil,
            provider: .claude
        )
        XCTAssertNil(summary)
    }

    // MARK: - liveSemanticKey

    func test_liveSemanticKey_preToolUseWithToolUseIdUsesId() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "PreToolUse",
            toolName: "Read",
            input: ["file_path": .string("/foo")],
            toolUseId: "abc123"
        )
        XCTAssertEqual(key, "tool-use:abc123")
    }

    func test_liveSemanticKey_toolPermissionFallsBackToToolPaths() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "ToolPermission",
            toolName: "Read",
            input: ["file_path": .string("/foo/Bar.swift")],
            toolUseId: nil
        )
        XCTAssertNotNil(key)
        XCTAssertTrue(key?.hasPrefix("tool:read:") ?? false,
                      "expected tool:read:* prefix, got: \(key ?? "nil")")
        XCTAssertTrue(key?.contains("paths:") ?? false)
    }

    func test_liveSemanticKey_subagentStartWithToolUseId() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "SubagentStart",
            toolName: "Reviewer",
            input: nil,
            toolUseId: "sub42"
        )
        XCTAssertEqual(key, "tool-use:sub42")
    }

    func test_liveSemanticKey_userPromptSubmitWithToolUseId() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "UserPromptSubmit",
            toolName: nil,
            input: nil,
            toolUseId: "u1"
        )
        XCTAssertEqual(key, "operation:userpromptsubmit:u1")
    }

    func test_liveSemanticKey_beforeModelNoToolUseId() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "BeforeModel",
            toolName: nil,
            input: nil,
            toolUseId: nil
        )
        XCTAssertEqual(key, "operation:beforemodel")
    }

    func test_liveSemanticKey_sessionStartNoToolUseId() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "SessionStart",
            toolName: nil,
            input: nil,
            toolUseId: nil
        )
        XCTAssertEqual(key, "operation:sessionstart")
    }

    func test_liveSemanticKey_unknownEventReturnsNil() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "PostToolUse",
            toolName: "Read",
            input: nil,
            toolUseId: "x"
        )
        XCTAssertNil(key)
    }

    func test_liveSemanticKey_preToolUseNoIdNoInputNoToolReturnsNil() {
        let key = ToolActivityFormatter.liveSemanticKey(
            rawEventName: "PreToolUse",
            toolName: nil,
            input: nil,
            toolUseId: nil
        )
        XCTAssertNil(key, "no tool name and no toolUseId means no key")
    }

    // MARK: - detailSummary

    func test_detailSummary_emptyInputReturnsNil() {
        let result = ToolActivityFormatter.detailSummary(tool: "Bash", input: [:])
        XCTAssertNil(result)
    }

    func test_detailSummary_bashCommandOnly() {
        let result = ToolActivityFormatter.detailSummary(
            tool: "Bash",
            input: ["command": .string("ls")]
        )
        XCTAssertEqual(result, "ls")
    }

    func test_detailSummary_bashPrefersDescriptionOverCommand() {
        let result = ToolActivityFormatter.detailSummary(
            tool: "Bash",
            input: [
                "description": .string("do thing"),
                "command": .string("ls")
            ]
        )
        XCTAssertEqual(result, "do thing")
    }

    func test_detailSummary_readUsesFilePath() {
        let result = ToolActivityFormatter.detailSummary(
            tool: "Read",
            input: ["file_path": .string("/foo/Bar.swift")]
        )
        XCTAssertEqual(result, "/foo/Bar.swift")
    }

    func test_detailSummary_unknownToolFallsBackToDefaultKeys() {
        let result = ToolActivityFormatter.detailSummary(
            tool: "MyCustomTool",
            input: ["query": .string("hello")]
        )
        XCTAssertEqual(result, "hello")
    }

    func test_detailSummary_unknownToolNoMatchedKeysJoinsPairs() {
        let result = ToolActivityFormatter.detailSummary(
            tool: "MyCustomTool",
            input: [
                "alpha": .string("a"),
                "beta": .string("b")
            ]
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("alpha: a") ?? false)
        XCTAssertTrue(result?.contains("beta: b") ?? false)
    }
}
