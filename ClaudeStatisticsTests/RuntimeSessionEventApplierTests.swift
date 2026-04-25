import Foundation
import XCTest

@testable import Claude_Statistics

final class RuntimeSessionEventApplierTests: XCTestCase {

    // MARK: - Factories

    /// Build a RuntimeSession via JSONDecoder (mirrors the approach used in
    /// `RuntimeStatePersistorTests` / `TerminalIdentityResolverTests`) so the
    /// caller only needs to specify the few fields that matter for the
    /// scenario under test.
    private func makeRuntime(
        provider: ProviderKind = .claude,
        sessionId: String = "session",
        lastActivityAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        latestProgressNote: String? = nil,
        latestProgressNoteAt: Date? = nil,
        latestPrompt: String? = nil,
        latestPromptAt: Date? = nil,
        latestPreview: String? = nil,
        latestPreviewAt: Date? = nil
    ) -> RuntimeSession {
        var json: [String: Any] = [
            "provider": provider.rawValue,
            "sessionId": sessionId,
            "lastActivityAt": lastActivityAt.timeIntervalSinceReferenceDate,
            "status": "idle",
            "backgroundShellCount": 0,
            "activeSubagentCount": 0,
            "activeTools": [String: Any](),
            "recentlyCompletedTools": [Any]()
        ]
        if let latestProgressNote { json["latestProgressNote"] = latestProgressNote }
        if let latestProgressNoteAt { json["latestProgressNoteAt"] = latestProgressNoteAt.timeIntervalSinceReferenceDate }
        if let latestPrompt { json["latestPrompt"] = latestPrompt }
        if let latestPromptAt { json["latestPromptAt"] = latestPromptAt.timeIntervalSinceReferenceDate }
        if let latestPreview { json["latestPreview"] = latestPreview }
        if let latestPreviewAt { json["latestPreviewAt"] = latestPreviewAt.timeIntervalSinceReferenceDate }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(RuntimeSession.self, from: data)
    }

    private func makeEvent(
        rawEventName: String,
        provider: ProviderKind = .claude,
        sessionId: String = "evt-session",
        toolName: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        toolUseId: String? = nil,
        toolResponse: String? = nil,
        receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_500),
        kind: AttentionKind = .activityPulse
    ) -> AttentionEvent {
        AttentionEvent(
            id: UUID(),
            provider: provider,
            rawEventName: rawEventName,
            notificationType: nil,
            toolName: toolName,
            toolInput: toolInput,
            toolUseId: toolUseId,
            toolResponse: toolResponse,
            message: nil,
            sessionId: sessionId,
            projectPath: nil,
            transcriptPath: nil,
            tty: nil,
            pid: nil,
            terminalName: nil,
            terminalSocket: nil,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            receivedAt: receivedAt,
            promptText: nil,
            commentaryText: nil,
            commentaryAt: nil,
            kind: kind,
            pending: nil
        )
    }

    // MARK: - apply: PreToolUse

    func test_apply_preToolUse_setsCurrentToolAndActiveTools() {
        var runtime = makeRuntime()
        let event = makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Read",
            toolInput: [:],
            toolUseId: "t1"
        )

        RuntimeSessionEventApplier.apply(event: event, to: &runtime)

        XCTAssertEqual(runtime.currentToolName, "Read", "PreToolUse sets currentToolName")
        XCTAssertEqual(runtime.currentToolUseId, "t1")
        XCTAssertNotNil(runtime.activeTools["t1"], "activeTools is keyed by toolUseId")
        XCTAssertEqual(runtime.activeTools["t1"]?.toolName, "Read")
    }

    func test_apply_preToolUse_backgroundBashIncrementsShellCount() {
        var runtime = makeRuntime()
        let event = makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Bash",
            toolInput: ["run_in_background": .bool(true)],
            toolUseId: "bg1"
        )

        RuntimeSessionEventApplier.apply(event: event, to: &runtime)

        XCTAssertEqual(runtime.backgroundShellCount, 1, "background bash bumps the counter")
    }

    func test_apply_preToolUse_foregroundBashDoesNotIncrementShellCount() {
        var runtime = makeRuntime()
        let event = makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Bash",
            toolInput: ["run_in_background": .bool(false)],
            toolUseId: "fg1"
        )

        RuntimeSessionEventApplier.apply(event: event, to: &runtime)

        XCTAssertEqual(runtime.backgroundShellCount, 0, "foreground bash leaves the counter alone")
    }

    // MARK: - apply: PostToolUse

    func test_apply_postToolUse_movesActiveEntryToRecentlyCompleted() {
        var runtime = makeRuntime()
        let pre = makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Read",
            toolInput: [:],
            toolUseId: "t1",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        RuntimeSessionEventApplier.apply(event: pre, to: &runtime)

        let post = makeEvent(
            rawEventName: "PostToolUse",
            toolName: "Read",
            toolInput: [:],
            toolUseId: "t1",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_510)
        )
        RuntimeSessionEventApplier.apply(event: post, to: &runtime)

        XCTAssertNil(runtime.activeTools["t1"], "activeTools entry is removed on PostToolUse")
        XCTAssertEqual(runtime.recentlyCompletedTools.first?.toolName, "Read", "completed entry is at the front of the recent buffer")
        XCTAssertEqual(runtime.recentlyCompletedTools.first?.failed, false)
    }

    func test_apply_postToolUse_clearsCurrentToolWhenIdMatches() {
        var runtime = makeRuntime()
        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Read",
            toolInput: [:],
            toolUseId: "t1"
        ), to: &runtime)

        XCTAssertEqual(runtime.currentToolName, "Read")

        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PostToolUse",
            toolName: "Read",
            toolInput: [:],
            toolUseId: "t1"
        ), to: &runtime)

        XCTAssertNil(runtime.currentToolName, "matching toolUseId clears currentToolName")
        XCTAssertNil(runtime.currentToolUseId)
    }

    func test_apply_postToolUseFailure_marksRecentEntryFailed() {
        var runtime = makeRuntime()
        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Bash",
            toolInput: [:],
            toolUseId: "t1"
        ), to: &runtime)

        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PostToolUseFailure",
            toolName: "Bash",
            toolInput: [:],
            toolUseId: "t1"
        ), to: &runtime)

        XCTAssertEqual(runtime.recentlyCompletedTools.first?.failed, true, "failure events flag the completed entry")
    }

    func test_apply_postToolUse_recentlyCompletedToolsCappedAtMax() {
        var runtime = makeRuntime()

        // Run six PreToolUse + PostToolUse pairs — buffer should keep 5.
        for i in 0..<6 {
            let id = "t\(i)"
            let pre = makeEvent(
                rawEventName: "PreToolUse",
                toolName: "Read",
                toolInput: [:],
                toolUseId: id,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 2))
            )
            RuntimeSessionEventApplier.apply(event: pre, to: &runtime)

            let post = makeEvent(
                rawEventName: "PostToolUse",
                toolName: "Read",
                toolInput: [:],
                toolUseId: id,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_001 + Double(i * 2))
            )
            RuntimeSessionEventApplier.apply(event: post, to: &runtime)
        }

        XCTAssertEqual(
            runtime.recentlyCompletedTools.count,
            ActiveSession.recentToolsMaxCount,
            "recentlyCompletedTools is capped at recentToolsMaxCount (5)"
        )
    }

    // MARK: - apply: PermissionRequest

    func test_apply_permissionRequest_setsApprovalFields() {
        var runtime = makeRuntime()
        let event = makeEvent(
            rawEventName: "PermissionRequest",
            toolName: "Bash",
            toolInput: [:],
            toolUseId: "approve-1",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_700)
        )

        RuntimeSessionEventApplier.apply(event: event, to: &runtime)

        XCTAssertEqual(runtime.approvalToolName, "Bash", "approvalToolName is set from the event")
        XCTAssertNotNil(runtime.approvalStartedAt, "approvalStartedAt is populated")
        XCTAssertEqual(runtime.approvalToolUseId, "approve-1")
    }

    // MARK: - apply: Subagent lifecycle

    func test_apply_subagentStart_incrementsCount() {
        var runtime = makeRuntime()
        XCTAssertEqual(runtime.activeSubagentCount, 0)

        RuntimeSessionEventApplier.apply(
            event: makeEvent(rawEventName: "SubagentStart"),
            to: &runtime
        )

        XCTAssertEqual(runtime.activeSubagentCount, 1)
    }

    func test_apply_subagentStop_decrementsCount() {
        var runtime = makeRuntime()
        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "SubagentStart"), to: &runtime)
        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "SubagentStart"), to: &runtime)
        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "SubagentStop"), to: &runtime)

        XCTAssertEqual(runtime.activeSubagentCount, 1, "SubagentStop decrements the counter")
    }

    func test_apply_subagentStop_clampedAtZero() {
        var runtime = makeRuntime()

        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "SubagentStop"), to: &runtime)

        XCTAssertEqual(runtime.activeSubagentCount, 0, "Stop without matching Start should not go negative")
    }

    // MARK: - apply: UserPromptSubmit / Stop / SessionEnd resets

    func test_apply_userPromptSubmit_clearsAllTurnState() {
        var runtime = makeRuntime()
        // Seed runtime with state from a previous turn.
        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Read",
            toolInput: [:],
            toolUseId: "t1"
        ), to: &runtime)
        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PermissionRequest",
            toolName: "Bash",
            toolInput: [:],
            toolUseId: "p1"
        ), to: &runtime)

        XCTAssertNotNil(runtime.currentToolName)
        XCTAssertNotNil(runtime.approvalToolName)
        XCTAssertFalse(runtime.activeTools.isEmpty)

        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "UserPromptSubmit"), to: &runtime)

        XCTAssertNil(runtime.currentToolName, "UserPromptSubmit clears currentToolName")
        XCTAssertNil(runtime.approvalToolName, "UserPromptSubmit clears approvalToolName")
        XCTAssertTrue(runtime.activeTools.isEmpty, "UserPromptSubmit empties activeTools")
        XCTAssertTrue(runtime.recentlyCompletedTools.isEmpty, "UserPromptSubmit empties recentlyCompletedTools")
    }

    func test_apply_stop_clearsTurnStateButKeepsBackgroundShellCount() {
        var runtime = makeRuntime()
        // Background bash from earlier in the turn.
        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Bash",
            toolInput: ["run_in_background": .bool(true)],
            toolUseId: "bg1"
        ), to: &runtime)
        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Read",
            toolInput: [:],
            toolUseId: "r1"
        ), to: &runtime)

        XCTAssertEqual(runtime.backgroundShellCount, 1)
        XCTAssertFalse(runtime.activeTools.isEmpty)

        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "Stop"), to: &runtime)

        XCTAssertNil(runtime.currentToolName, "Stop clears currentToolName")
        XCTAssertTrue(runtime.activeTools.isEmpty, "Stop empties activeTools")
        XCTAssertEqual(runtime.backgroundShellCount, 1, "Stop preserves backgroundShellCount — bg shells outlive the turn")
    }

    func test_apply_sessionEnd_clearsEverythingIncludingCounts() {
        var runtime = makeRuntime()
        RuntimeSessionEventApplier.apply(event: makeEvent(
            rawEventName: "PreToolUse",
            toolName: "Bash",
            toolInput: ["run_in_background": .bool(true)],
            toolUseId: "bg1"
        ), to: &runtime)
        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "SubagentStart"), to: &runtime)

        XCTAssertEqual(runtime.backgroundShellCount, 1)
        XCTAssertEqual(runtime.activeSubagentCount, 1)

        RuntimeSessionEventApplier.apply(event: makeEvent(rawEventName: "SessionEnd"), to: &runtime)

        XCTAssertEqual(runtime.backgroundShellCount, 0, "SessionEnd resets backgroundShellCount")
        XCTAssertEqual(runtime.activeSubagentCount, 0, "SessionEnd resets activeSubagentCount")
        XCTAssertTrue(runtime.activeTools.isEmpty)
        XCTAssertTrue(runtime.recentlyCompletedTools.isEmpty)
    }

    // MARK: - signals

    func test_signals_bothNilReturnsEmpty() {
        let signals = RuntimeSessionEventApplier.signals(from: nil, stats: nil)
        XCTAssertTrue(signals.isEmpty, "no source data means no signals")
    }

    func test_signals_quickWithPromptOnlyEmitsPromptSignal() {
        var quick = SessionQuickStats()
        quick.lastPrompt = "Refactor the parser"
        quick.lastPromptAt = Date(timeIntervalSince1970: 1_700_000_900)

        let signals = RuntimeSessionEventApplier.signals(from: quick, stats: nil)

        XCTAssertEqual(signals.count, 1, "only prompt is populated")
        XCTAssertEqual(signals.first?.kind, .prompt)
        XCTAssertEqual(signals.first?.text, "Refactor the parser")
    }

    func test_signals_statsWithAllThreeFieldsEmitsThreeSignals() {
        var stats = SessionStats()
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        stats.latestProgressNote = "Reading the file"
        stats.latestProgressNoteAt = now
        stats.lastOutputPreview = "stdout sample"
        stats.lastOutputPreviewAt = now.addingTimeInterval(1)
        stats.lastPrompt = "Do the thing"
        stats.lastPromptAt = now.addingTimeInterval(2)

        let signals = RuntimeSessionEventApplier.signals(from: nil, stats: stats)

        XCTAssertEqual(signals.count, 3, "all three signal kinds are emitted")
        let kinds = Set(signals.map { $0.kind })
        XCTAssertTrue(kinds.contains(.progressNote))
        XCTAssertTrue(kinds.contains(.preview))
        XCTAssertTrue(kinds.contains(.prompt))
    }

    func test_signals_statsTakesPrecedenceOverQuick() {
        var quick = SessionQuickStats()
        quick.latestProgressNote = "from quick"
        quick.latestProgressNoteAt = Date(timeIntervalSince1970: 1_700_000_900)

        var stats = SessionStats()
        stats.latestProgressNote = "from stats"
        stats.latestProgressNoteAt = Date(timeIntervalSince1970: 1_700_000_950)

        let signals = RuntimeSessionEventApplier.signals(from: quick, stats: stats)

        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.text, "from stats", "stats wins over quick when both are present for the same field")
    }

    // MARK: - merge

    func test_merge_emptySignalsLeavesRuntimeUnchanged() {
        let original = makeRuntime(
            latestProgressNote: "untouched",
            latestProgressNoteAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var runtime = original

        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [])

        XCTAssertEqual(runtime, original, "empty signals must not mutate runtime")
    }

    func test_merge_newerProgressNoteOverwrites() {
        let oldAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newerAt = oldAt.addingTimeInterval(60)
        var runtime = makeRuntime(
            lastActivityAt: oldAt,
            latestProgressNote: "old note",
            latestProgressNoteAt: oldAt
        )

        let signal = RuntimeSignal(kind: .progressNote, text: "new note", timestamp: newerAt)
        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [signal])

        XCTAssertEqual(runtime.latestProgressNote, "new note", "newer signal overwrites the existing note")
        XCTAssertEqual(runtime.latestProgressNoteAt, newerAt)
        XCTAssertEqual(runtime.lastActivityAt, newerAt, "lastActivityAt advances to the newer signal time")
    }

    func test_merge_olderProgressNoteIsIgnored() {
        let existingAt = Date(timeIntervalSince1970: 1_700_000_500)
        let olderAt = existingAt.addingTimeInterval(-60)
        var runtime = makeRuntime(
            latestProgressNote: "current",
            latestProgressNoteAt: existingAt
        )

        let signal = RuntimeSignal(kind: .progressNote, text: "stale", timestamp: olderAt)
        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [signal])

        XCTAssertEqual(runtime.latestProgressNote, "current", "older signal must not overwrite")
        XCTAssertEqual(runtime.latestProgressNoteAt, existingAt)
    }

    func test_merge_sameTimestampDifferentTextOverwrites() {
        let when = Date(timeIntervalSince1970: 1_700_000_500)
        var runtime = makeRuntime(
            latestProgressNote: "lower case",
            latestProgressNoteAt: when
        )

        let signal = RuntimeSignal(kind: .progressNote, text: "Different Text", timestamp: when)
        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [signal])

        XCTAssertEqual(runtime.latestProgressNote, "Different Text", "same timestamp + different text overwrites")
    }

    func test_merge_sameTimestampSameTextCaseInsensitiveDoesNotOverwrite() {
        let when = Date(timeIntervalSince1970: 1_700_000_500)
        var runtime = makeRuntime(
            latestProgressNote: "Hello World",
            latestProgressNoteAt: when
        )

        let signal = RuntimeSignal(kind: .progressNote, text: "hello WORLD", timestamp: when)
        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [signal])

        XCTAssertEqual(runtime.latestProgressNote, "Hello World", "case-insensitive equality blocks overwrite")
    }

    func test_merge_emptyTextDoesNotOverwrite() {
        let existingAt = Date(timeIntervalSince1970: 1_700_000_500)
        let newerAt = existingAt.addingTimeInterval(60)
        var runtime = makeRuntime(
            latestProgressNote: "kept",
            latestProgressNoteAt: existingAt
        )

        let signal = RuntimeSignal(kind: .progressNote, text: "   \n  ", timestamp: newerAt)
        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [signal])

        XCTAssertEqual(runtime.latestProgressNote, "kept", "whitespace-only text fails the freshness check")
        XCTAssertEqual(runtime.latestProgressNoteAt, existingAt)
    }

    func test_merge_promptDoesNotAdvanceLastActivityAt() {
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let promptAt = baseline.addingTimeInterval(120)
        var runtime = makeRuntime(lastActivityAt: baseline)

        let signal = RuntimeSignal(kind: .prompt, text: "user typed something", timestamp: promptAt)
        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [signal])

        XCTAssertEqual(runtime.latestPrompt, "user typed something")
        XCTAssertEqual(runtime.lastActivityAt, baseline, "prompt signals do NOT advance lastActivityAt — only progressNote/preview do")
    }

    func test_merge_previewAdvancesLastActivityAt() {
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let previewAt = baseline.addingTimeInterval(120)
        var runtime = makeRuntime(lastActivityAt: baseline)

        let signal = RuntimeSignal(kind: .preview, text: "stdout chunk", timestamp: previewAt)
        RuntimeSessionEventApplier.merge(runtime: &runtime, signals: [signal])

        XCTAssertEqual(runtime.latestPreview, "stdout chunk")
        XCTAssertEqual(runtime.lastActivityAt, previewAt, "preview signals advance lastActivityAt")
    }

    // MARK: - deriveStatus

    func test_deriveStatus_permissionRequestReturnsApproval() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .permissionRequest(tool: "Bash", input: [:], toolUseId: "t1", interaction: .actionable),
            rawName: "PermissionRequest",
            previous: .idle,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .approval)
    }

    func test_deriveStatus_taskFailedReturnsFailed() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .taskFailed(summary: nil),
            rawName: "StopFailure",
            previous: .running,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .failed)
    }

    func test_deriveStatus_taskDoneReturnsDone() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .taskDone(summary: nil),
            rawName: "Stop",
            previous: .running,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .done)
    }

    func test_deriveStatus_sessionStartReturnsWaiting() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .sessionStart(source: nil),
            rawName: "SessionStart",
            previous: .idle,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .waiting, "fresh session is waiting, not running")
    }

    func test_deriveStatus_waitingInputWithoutActiveOperationReturnsWaiting() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .waitingInput(message: nil),
            rawName: "Notification",
            previous: .running,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .waiting)
    }

    func test_deriveStatus_waitingInputWithActiveOperationKeepsApproval() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .waitingInput(message: nil),
            rawName: "Notification",
            previous: .approval,
            hadActiveOperation: true
        )
        XCTAssertEqual(result, .approval, "approval is more truthful than waiting when both signals fire together")
    }

    func test_deriveStatus_waitingInputWithActiveOperationFromIdleReturnsRunning() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .waitingInput(message: nil),
            rawName: "Notification",
            previous: .idle,
            hadActiveOperation: true
        )
        XCTAssertEqual(result, .running, "active operation overrides idle_prompt to running")
    }

    func test_deriveStatus_activityPulsePreToolUseReturnsRunning() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .activityPulse,
            rawName: "PreToolUse",
            previous: .idle,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .running)
    }

    func test_deriveStatus_activityPulsePostToolUseFromApprovalReturnsRunning() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .activityPulse,
            rawName: "PostToolUse",
            previous: .approval,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .running, "PostToolUse clears stale approval state")
    }

    func test_deriveStatus_activityPulsePostToolUseFromRunningStaysRunning() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .activityPulse,
            rawName: "PostToolUse",
            previous: .running,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .running, "running stays running across PostToolUse")
    }

    func test_deriveStatus_activityPulsePostCompactReturnsRunning() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .activityPulse,
            rawName: "PostCompact",
            previous: .idle,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .running)
    }

    func test_deriveStatus_sessionEndReturnsPrevious() {
        let result = RuntimeSessionEventApplier.deriveStatus(
            for: .sessionEnd,
            rawName: "SessionEnd",
            previous: .done,
            hadActiveOperation: false
        )
        XCTAssertEqual(result, .done, "sessionEnd is a pass-through — caller drops the runtime entry")
    }
}
