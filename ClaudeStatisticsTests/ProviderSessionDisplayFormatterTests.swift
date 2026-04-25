import XCTest

@testable import Claude_Statistics

final class ProviderSessionDisplayFormatterTests: XCTestCase {
    private let now = Date()

    private func makeSession(
        provider: ProviderKind = .claude,
        status: ActiveSessionStatus = .running,
        latestPrompt: String? = nil,
        latestPromptAt: Date? = nil,
        latestProgressNote: String? = nil,
        latestProgressNoteAt: Date? = nil,
        latestPreview: String? = nil,
        latestPreviewAt: Date? = nil,
        currentActivity: String? = nil,
        currentOperation: CurrentOperation? = nil,
        currentToolName: String? = nil,
        currentToolDetail: String? = nil,
        currentToolStartedAt: Date? = nil,
        activeTools: [String: ActiveToolEntry] = [:],
        recentlyCompletedTools: [CompletedToolEntry] = [],
        activeSubagentCount: Int = 0,
        approvalToolName: String? = nil,
        approvalToolDetail: String? = nil,
        approvalStartedAt: Date? = nil,
        latestToolOutput: String? = nil,
        latestToolOutputSummary: ToolOutputSummary? = nil,
        latestToolOutputAt: Date? = nil,
        latestToolOutputTool: String? = nil,
        lastActivityAt: Date? = nil
    ) -> ActiveSession {
        ActiveSession(
            id: "test-id",
            sessionId: "test-session",
            provider: provider,
            projectName: "TestProject",
            projectPath: nil,
            currentActivity: currentActivity,
            currentActivitySemanticKey: nil,
            latestProgressNote: latestProgressNote,
            latestProgressNoteAt: latestProgressNoteAt,
            latestPrompt: latestPrompt,
            latestPromptAt: latestPromptAt,
            latestPreview: latestPreview,
            latestPreviewAt: latestPreviewAt,
            lastActivityAt: lastActivityAt ?? now,
            currentOperation: currentOperation,
            tty: nil,
            pid: nil,
            terminalName: nil,
            terminalSocket: nil,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            status: status,
            latestToolOutput: latestToolOutput,
            latestToolOutputSummary: latestToolOutputSummary,
            latestToolOutputAt: latestToolOutputAt,
            latestToolOutputTool: latestToolOutputTool,
            currentToolName: currentToolName,
            currentToolDetail: currentToolDetail,
            currentToolStartedAt: currentToolStartedAt,
            approvalToolName: approvalToolName,
            approvalToolDetail: approvalToolDetail,
            approvalStartedAt: approvalStartedAt,
            approvalToolUseId: nil,
            backgroundShellCount: 0,
            activeSubagentCount: activeSubagentCount,
            activeTools: activeTools,
            recentlyCompletedTools: recentlyCompletedTools
        )
    }

    private func format(_ session: ActiveSession) -> ProviderSessionDisplayContent {
        ProviderSessionDisplayFormatter(session: session).content
    }

    // MARK: - isChronologicallyReversed

    func test_chronoReversed_bothNilFalse() {
        let content = ProviderSessionDisplayContent(
            promptText: "p", promptSymbol: "s",
            actionText: "a", actionSymbol: "s",
            actionTimestamp: nil,
            commentaryText: "c", commentarySymbol: "s",
            commentaryTimestamp: nil
        )
        XCTAssertFalse(content.isChronologicallyReversed)
    }

    func test_chronoReversed_actionMissingFalse() {
        let content = ProviderSessionDisplayContent(
            promptText: "p", promptSymbol: "s",
            actionText: "a", actionSymbol: "s",
            actionTimestamp: nil,
            commentaryText: "c", commentarySymbol: "s",
            commentaryTimestamp: now
        )
        XCTAssertFalse(content.isChronologicallyReversed)
    }

    func test_chronoReversed_commentaryMissingFalse() {
        let content = ProviderSessionDisplayContent(
            promptText: "p", promptSymbol: "s",
            actionText: "a", actionSymbol: "s",
            actionTimestamp: now,
            commentaryText: "c", commentarySymbol: "s",
            commentaryTimestamp: nil
        )
        XCTAssertFalse(content.isChronologicallyReversed)
    }

    func test_chronoReversed_commentaryBeforeActionTrue() {
        let content = ProviderSessionDisplayContent(
            promptText: "p", promptSymbol: "s",
            actionText: "a", actionSymbol: "s",
            actionTimestamp: now,
            commentaryText: "c", commentarySymbol: "s",
            commentaryTimestamp: now.addingTimeInterval(-10)
        )
        XCTAssertTrue(content.isChronologicallyReversed)
    }

    func test_chronoReversed_actionBeforeCommentaryFalse() {
        let content = ProviderSessionDisplayContent(
            promptText: "p", promptSymbol: "s",
            actionText: "a", actionSymbol: "s",
            actionTimestamp: now,
            commentaryText: "c", commentarySymbol: "s",
            commentaryTimestamp: now.addingTimeInterval(10)
        )
        XCTAssertFalse(content.isChronologicallyReversed)
    }

    // MARK: - resolvePromptLine

    func test_prompt_returnsCleanedPrompt() {
        let session = makeSession(latestPrompt: "Refactor the formatter")
        let content = format(session)
        XCTAssertEqual(content.promptText, "Refactor the formatter")
        XCTAssertEqual(content.promptSymbol, "person.fill")
    }

    func test_prompt_emptyFallsBackToPlaceholder() {
        let session = makeSession(latestPrompt: nil)
        let content = format(session)
        XCTAssertFalse(content.promptText.isEmpty)
        XCTAssertEqual(content.promptSymbol, "person.crop.circle.dashed")
    }

    func test_prompt_internalMarkupIsTreatedAsAbsent() {
        let session = makeSession(latestPrompt: "<system-reminder>secret</system-reminder>")
        let content = format(session)
        XCTAssertEqual(content.promptSymbol, "person.crop.circle.dashed")
    }

    // MARK: - resolveActionLine — candidate priority

    func test_action_activeToolsSummaryWinsWhenMultipleToolsRunning() {
        let session = makeSession(
            currentToolName: "Read",
            currentToolStartedAt: now,
            activeTools: [
                "k1": ActiveToolEntry(toolName: "Read", detail: nil, startedAt: now),
                "k2": ActiveToolEntry(toolName: "Read", detail: nil, startedAt: now),
                "k3": ActiveToolEntry(toolName: "Grep", detail: nil, startedAt: now)
            ]
        )
        let content = format(session)
        XCTAssertTrue(content.actionText.contains(" · "), "aggregate should join with · separator")
    }

    func test_action_currentOperationTextShown() {
        let session = makeSession(
            currentOperation: CurrentOperation(
                kind: .tool,
                text: "Reading foo.swift",
                symbol: "doc.text",
                startedAt: now,
                toolName: "Read",
                toolUseId: "u1"
            )
        )
        let content = format(session)
        XCTAssertEqual(content.actionText, "Reading foo.swift")
        XCTAssertEqual(content.actionSymbol, "doc.text")
    }

    func test_action_currentActivityShownWhenNoOperation() {
        let session = makeSession(
            currentActivity: "Drafting reply",
            currentToolName: "Read"
        )
        let content = format(session)
        XCTAssertEqual(content.actionText, "Drafting reply")
    }

    func test_action_currentToolDetailShownWhenOnlyDetailAvailable() {
        let session = makeSession(currentToolName: "Edit", currentToolDetail: "Edit foo.swift")
        let content = format(session)
        XCTAssertEqual(content.actionText, "Edit foo.swift")
    }

    // MARK: - resolveActionLine — fallback by status

    func test_action_runningFallbackThinking() {
        let session = makeSession(status: .running)
        let content = format(session)
        XCTAssertFalse(content.actionText.isEmpty)
        XCTAssertEqual(content.actionSymbol, "hourglass")
        XCTAssertNil(content.actionTimestamp, ".running fallback keeps timestamp nil")
    }

    func test_action_doneFallbackHasTimestamp() {
        let session = makeSession(status: .done)
        let content = format(session)
        XCTAssertEqual(content.actionSymbol, "checkmark.circle")
        XCTAssertNotNil(content.actionTimestamp, "done fallback stamps Date() so reversal works")
    }

    func test_action_failedFallbackHasTimestamp() {
        let session = makeSession(status: .failed)
        let content = format(session)
        XCTAssertEqual(content.actionSymbol, "exclamationmark.triangle")
        XCTAssertNotNil(content.actionTimestamp)
    }

    func test_action_idleFallbackHasTimestamp() {
        let session = makeSession(status: .idle, lastActivityAt: now.addingTimeInterval(-1000))
        let content = format(session)
        XCTAssertEqual(content.actionSymbol, "moon.zzz")
        XCTAssertNotNil(content.actionTimestamp)
    }

    func test_action_waitingFallbackHasTimestamp() {
        let session = makeSession(status: .waiting)
        let content = format(session)
        XCTAssertEqual(content.actionSymbol, "return")
        XCTAssertNotNil(content.actionTimestamp)
    }

    func test_action_approvalFallbackKeepsTimestampNil() {
        let session = makeSession(
            status: .approval,
            approvalToolName: "Bash",
            approvalToolDetail: "git push",
            approvalStartedAt: now
        )
        let content = format(session)
        XCTAssertEqual(content.actionSymbol, "lock.fill")
        XCTAssertNil(content.actionTimestamp, ".approval keeps fallback timestamp nil")
    }

    // MARK: - resolveActionLine — actionTimestamp

    func test_actionTimestamp_usesLatestActiveToolStart() {
        let early = now.addingTimeInterval(-30)
        let late = now.addingTimeInterval(-1)
        let session = makeSession(
            activeTools: [
                "k1": ActiveToolEntry(toolName: "Task", detail: nil, startedAt: early),
                "k2": ActiveToolEntry(toolName: "Read", detail: nil, startedAt: late),
                "k3": ActiveToolEntry(toolName: "Read", detail: nil, startedAt: early)
            ]
        )
        // Need 2+ tools so activeToolsSummaryCandidate fires and timestamp is
        // evaluated.
        let content = format(session)
        XCTAssertEqual(content.actionTimestamp, late, "uses .max of active tool start times")
    }

    func test_actionTimestamp_fallsBackToCurrentToolStartedAt() {
        // currentToolDetail makes the candidate fire so actionTimestamp is
        // evaluated; otherwise we'd take the fallback path (which has its own
        // timestamp logic, tested separately).
        let started = now.addingTimeInterval(-5)
        let session = makeSession(
            currentToolName: "Read",
            currentToolDetail: "Reading bar.swift",
            currentToolStartedAt: started
        )
        let content = format(session)
        XCTAssertEqual(content.actionTimestamp, started)
    }

    func test_actionTimestamp_fallsBackToRecentlyCompletedWithinWindow() {
        let completed = now.addingTimeInterval(-2)
        let session = makeSession(
            currentToolName: "Read",
            currentToolDetail: "Reading bar.swift",
            recentlyCompletedTools: [
                CompletedToolEntry(
                    toolName: "Read",
                    detail: nil,
                    startedAt: now.addingTimeInterval(-3),
                    completedAt: completed,
                    failed: false
                )
            ]
        )
        let content = format(session)
        XCTAssertEqual(content.actionTimestamp, completed)
    }

    func test_actionTimestamp_oldRecentlyCompletedIgnored() {
        let session = makeSession(
            recentlyCompletedTools: [
                CompletedToolEntry(
                    toolName: "Read",
                    detail: nil,
                    startedAt: now.addingTimeInterval(-3600),
                    completedAt: now.addingTimeInterval(-3600),
                    failed: false
                )
            ]
        )
        let content = format(session)
        // .running fallback path → timestamp nil
        XCTAssertNil(content.actionTimestamp)
    }

    // MARK: - resolveCommentaryLine

    func test_commentary_approvalDetailShownWhenApproval() {
        let session = makeSession(
            status: .approval,
            approvalToolName: "Bash",
            approvalToolDetail: "git push origin main",
            approvalStartedAt: now
        )
        let content = format(session)
        XCTAssertEqual(content.commentaryText, "git push origin main")
        XCTAssertEqual(content.commentarySymbol, "terminal")
        XCTAssertEqual(content.commentaryTimestamp, now)
    }

    func test_commentary_currentTurnProgressNoteShown() {
        let promptAt = now.addingTimeInterval(-10)
        let noteAt = now.addingTimeInterval(-2)
        let session = makeSession(
            latestPrompt: "Hi",
            latestPromptAt: promptAt,
            latestProgressNote: "Let me check…",
            latestProgressNoteAt: noteAt
        )
        let content = format(session)
        XCTAssertEqual(content.commentaryText, "Let me check…")
        XCTAssertEqual(content.commentarySymbol, "sparkles")
        XCTAssertEqual(content.commentaryTimestamp, noteAt)
    }

    func test_commentary_pastTurnProgressNoteFallsBackToWaitingForReply() {
        // commentary timestamp is BEFORE the latest prompt — past turn.
        let session = makeSession(
            latestPrompt: "New question",
            latestPromptAt: now,
            latestProgressNote: "Old reply from earlier",
            latestProgressNoteAt: now.addingTimeInterval(-60)
        )
        let content = format(session)
        XCTAssertNotEqual(content.commentaryText, "Old reply from earlier")
        XCTAssertEqual(content.commentarySymbol, "ellipsis.bubble")
        XCTAssertNil(content.commentaryTimestamp)
    }

    func test_commentary_noPromptUsesWaitingForInput() {
        let session = makeSession(latestPrompt: nil)
        let content = format(session)
        XCTAssertEqual(content.commentarySymbol, "ellipsis.bubble")
        XCTAssertFalse(content.commentaryText.isEmpty)
    }

    func test_commentary_promptButNoNoteUsesWaitingForReply() {
        let session = makeSession(latestPrompt: "Hi", latestPromptAt: now)
        let content = format(session)
        XCTAssertEqual(content.commentarySymbol, "ellipsis.bubble")
        XCTAssertFalse(content.commentaryText.isEmpty)
    }

    func test_commentary_freshSessionWithNoPromptKeepsNote() {
        // No prompt yet → anything we have is "current turn" by definition.
        let session = makeSession(
            latestPrompt: nil,
            latestProgressNote: "Welcome message",
            latestProgressNoteAt: now
        )
        let content = format(session)
        XCTAssertEqual(content.commentaryText, "Welcome message")
    }

    func test_commentary_internalMarkupSuppressed() {
        let session = makeSession(
            latestPrompt: "Hi",
            latestPromptAt: now.addingTimeInterval(-5),
            latestProgressNote: "<system-reminder>noisy</system-reminder>",
            latestProgressNoteAt: now
        )
        let content = format(session)
        XCTAssertEqual(content.commentarySymbol, "ellipsis.bubble", "markup gets dropped → fallback")
    }

    // MARK: - currentTurn timestamp boundary

    func test_commentary_sameTimestampAsPromptCountsAsCurrentTurn() {
        // Commentary at exactly the prompt time — boundary case, current turn.
        let stamp = now.addingTimeInterval(-1)
        let session = makeSession(
            latestPrompt: "Hi",
            latestPromptAt: stamp,
            latestProgressNote: "Right on the boundary",
            latestProgressNoteAt: stamp
        )
        let content = format(session)
        XCTAssertEqual(content.commentaryText, "Right on the boundary")
    }

    // MARK: - approval label uses pretty tool name

    func test_action_approvalFallbackUsesPrettyToolName() {
        let session = makeSession(
            status: .approval,
            approvalToolName: "bash",
            approvalStartedAt: now
        )
        let content = format(session)
        XCTAssertTrue(
            content.actionText.contains("Command"),
            "bash → 'Command' via prettyToolName, got '\(content.actionText)'"
        )
    }

    // MARK: - back-compat shims

    func test_content_legacyAccessorsMirrorTriptychFields() {
        let session = makeSession(
            latestPrompt: "P",
            currentOperation: CurrentOperation(
                kind: .tool,
                text: "Reading X",
                symbol: "doc.text",
                startedAt: now,
                toolName: "Read",
                toolUseId: "u1"
            )
        )
        let content = format(session)
        XCTAssertEqual(content.operationLineText, content.actionText)
        XCTAssertEqual(content.operationLineSymbol, content.actionSymbol)
        XCTAssertEqual(content.supportingLineText, content.commentaryText)
        XCTAssertEqual(content.supportingLineSymbol, content.commentarySymbol)
    }

    // MARK: - approval priority over commentary

    func test_commentary_approvalBeatsRecentNote() {
        let session = makeSession(
            status: .approval,
            latestProgressNote: "Should not appear",
            latestProgressNoteAt: now,
            approvalToolName: "Bash",
            approvalToolDetail: "rm -rf /",
            approvalStartedAt: now
        )
        let content = format(session)
        XCTAssertEqual(content.commentaryText, "rm -rf /")
    }

    // MARK: - tool output as commentary candidate via dialogue ordering
    // The triptych formatter doesn't surface latestToolOutput directly in
    // commentary (commentary is progress-note-driven), but a tool output
    // shouldn't break action either.

    func test_action_doesNotCrashOnFullySpecifiedSession() {
        let session = makeSession(
            status: .running,
            latestPrompt: "Hi",
            latestPromptAt: now.addingTimeInterval(-10),
            latestProgressNote: "thinking…",
            latestProgressNoteAt: now.addingTimeInterval(-5),
            latestPreview: "preview line",
            latestPreviewAt: now.addingTimeInterval(-3),
            currentActivity: "Working…",
            currentToolName: "Read",
            currentToolDetail: "Reading bar.swift",
            currentToolStartedAt: now.addingTimeInterval(-2),
            activeTools: [
                "k1": ActiveToolEntry(toolName: "Read", detail: nil, startedAt: now.addingTimeInterval(-2))
            ]
        )
        let content = format(session)
        XCTAssertFalse(content.actionText.isEmpty)
        XCTAssertFalse(content.commentaryText.isEmpty)
        XCTAssertFalse(content.promptText.isEmpty)
    }
}
