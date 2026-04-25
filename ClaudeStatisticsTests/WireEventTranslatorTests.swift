import XCTest

@testable import Claude_Statistics

final class WireEventTranslatorTests: XCTestCase {
    // MARK: - translateKind

    func test_translateKind_permissionRequestActionable() {
        let kind = WireEventTranslator.translateKind(
            event: "PermissionRequest",
            notificationType: nil,
            summary: nil
        )
        if case .permissionRequest(_, _, _, let interaction) = kind {
            XCTAssertEqual(interaction, .actionable)
        } else {
            XCTFail("expected .permissionRequest, got \(kind)")
        }
    }

    func test_translateKind_toolPermissionPassive() {
        let kind = WireEventTranslator.translateKind(
            event: "ToolPermission",
            notificationType: nil,
            summary: nil
        )
        if case .permissionRequest(_, _, _, let interaction) = kind {
            XCTAssertEqual(interaction, .passive)
        } else {
            XCTFail("expected .permissionRequest, got \(kind)")
        }
    }

    func test_translateKind_stopBecomesTaskDone() {
        let kind = WireEventTranslator.translateKind(
            event: "Stop",
            notificationType: nil,
            summary: "all good"
        )
        if case .taskDone(let summary) = kind {
            XCTAssertEqual(summary, "all good")
        } else {
            XCTFail("expected .taskDone, got \(kind)")
        }
    }

    func test_translateKind_stopFailureBecomesTaskFailed() {
        let kind = WireEventTranslator.translateKind(
            event: "StopFailure",
            notificationType: nil,
            summary: "error 42"
        )
        if case .taskFailed(let summary) = kind {
            XCTAssertEqual(summary, "error 42")
        } else {
            XCTFail("expected .taskFailed, got \(kind)")
        }
    }

    func test_translateKind_subagentStopIsActivityPulse() {
        let kind = WireEventTranslator.translateKind(event: "SubagentStop", notificationType: nil, summary: nil)
        XCTAssertEqual(kind, .activityPulse)
    }

    func test_translateKind_sessionStartCarriesSource() {
        let kind = WireEventTranslator.translateKind(
            event: "SessionStart",
            notificationType: nil,
            summary: "fresh"
        )
        if case .sessionStart(let source) = kind {
            XCTAssertEqual(source, "fresh")
        } else {
            XCTFail("expected .sessionStart, got \(kind)")
        }
    }

    func test_translateKind_sessionEnd() {
        let kind = WireEventTranslator.translateKind(event: "SessionEnd", notificationType: nil, summary: nil)
        XCTAssertEqual(kind, .sessionEnd)
    }

    func test_translateKind_notificationIdlePromptBecomesWaitingInput() {
        let kind = WireEventTranslator.translateKind(
            event: "Notification",
            notificationType: "idle_prompt",
            summary: "Need input"
        )
        if case .waitingInput(let message) = kind {
            XCTAssertEqual(message, "Need input")
        } else {
            XCTFail("expected .waitingInput, got \(kind)")
        }
    }

    func test_translateKind_notificationPermissionPromptIsActivityPulse() {
        let kind = WireEventTranslator.translateKind(
            event: "Notification",
            notificationType: "permission_prompt",
            summary: nil
        )
        XCTAssertEqual(kind, .activityPulse)
    }

    func test_translateKind_notificationUnknownTypeFallsBackToActivityPulse() {
        let kind = WireEventTranslator.translateKind(
            event: "Notification",
            notificationType: "completely_made_up",
            summary: nil
        )
        XCTAssertEqual(kind, .activityPulse)
    }

    func test_translateKind_silentEventsAreActivityPulse() {
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PostToolUseFailure", "SubagentStart", "PreCompact", "PostCompact"] {
            let kind = WireEventTranslator.translateKind(event: event, notificationType: nil, summary: nil)
            XCTAssertEqual(kind, .activityPulse, "expected \(event) → .activityPulse")
        }
    }

    func test_translateKind_unknownEventDefaultsToActivityPulse() {
        let kind = WireEventTranslator.translateKind(
            event: "FutureEventWeDontKnow",
            notificationType: nil,
            summary: nil
        )
        XCTAssertEqual(kind, .activityPulse)
    }

    // MARK: - translateProvider

    func test_translateProvider_codex() {
        XCTAssertEqual(WireEventTranslator.translateProvider("codex"), .codex)
    }

    func test_translateProvider_gemini() {
        XCTAssertEqual(WireEventTranslator.translateProvider("gemini"), .gemini)
    }

    func test_translateProvider_claudeExplicit() {
        XCTAssertEqual(WireEventTranslator.translateProvider("claude"), .claude)
    }

    func test_translateProvider_nilDefaultsToClaude() {
        XCTAssertEqual(WireEventTranslator.translateProvider(nil), .claude)
    }

    func test_translateProvider_unknownDefaultsToClaude() {
        XCTAssertEqual(WireEventTranslator.translateProvider("aurora"), .claude)
    }

    // MARK: - parseIsoTimestamp

    func test_parseIsoTimestamp_fractionalSeconds() {
        let parsed = WireEventTranslator.parseIsoTimestamp("2026-04-24T10:42:56.566Z")
        XCTAssertNotNil(parsed)
    }

    func test_parseIsoTimestamp_wholeSeconds() {
        let parsed = WireEventTranslator.parseIsoTimestamp("2026-04-24T10:42:56Z")
        XCTAssertNotNil(parsed)
    }

    func test_parseIsoTimestamp_emptyReturnsNil() {
        XCTAssertNil(WireEventTranslator.parseIsoTimestamp(""))
        XCTAssertNil(WireEventTranslator.parseIsoTimestamp("   "))
    }

    func test_parseIsoTimestamp_garbageReturnsNil() {
        XCTAssertNil(WireEventTranslator.parseIsoTimestamp("not a date"))
    }

    func test_parseIsoTimestamp_whitespaceTrimmed() {
        let parsed = WireEventTranslator.parseIsoTimestamp("  2026-04-24T10:42:56Z  ")
        XCTAssertNotNil(parsed)
    }

    // MARK: - jsonKindLabel

    func test_jsonKindLabel_string() {
        XCTAssertEqual(WireEventTranslator.jsonKindLabel(.string("hello")), "string")
    }

    func test_jsonKindLabel_number() {
        XCTAssertEqual(WireEventTranslator.jsonKindLabel(.number(42)), "number")
    }

    func test_jsonKindLabel_bool() {
        XCTAssertEqual(WireEventTranslator.jsonKindLabel(.bool(true)), "bool")
    }

    func test_jsonKindLabel_null() {
        XCTAssertEqual(WireEventTranslator.jsonKindLabel(.null), "null")
    }

    func test_jsonKindLabel_arrayIncludesCount() {
        let label = WireEventTranslator.jsonKindLabel(.array([.string("a"), .string("b"), .string("c")]))
        XCTAssertEqual(label, "array(3)")
    }

    func test_jsonKindLabel_objectIncludesCount() {
        let label = WireEventTranslator.jsonKindLabel(.object(["k1": .string("v"), "k2": .number(1)]))
        XCTAssertEqual(label, "object(2)")
    }

    // MARK: - resolvePermissionFields

    func test_resolvePermission_overlaysToolFields() {
        let placeholder = AttentionKind.permissionRequest(tool: "", input: [:], toolUseId: "", interaction: .actionable)
        let msg = makeMessage(event: "PermissionRequest", toolName: "Bash", toolInput: ["cmd": .string("ls")], toolUseId: "t1")
        let resolved = WireEventTranslator.resolvePermissionFields(placeholder, in: msg)
        if case .permissionRequest(let tool, let input, let toolUseId, let interaction) = resolved {
            XCTAssertEqual(tool, "Bash")
            XCTAssertEqual(input.count, 1)
            XCTAssertEqual(toolUseId, "t1")
            XCTAssertEqual(interaction, .actionable, "interaction preserved from input kind")
        } else {
            XCTFail("expected .permissionRequest, got \(resolved)")
        }
    }

    func test_resolvePermission_preservesPassiveInteraction() {
        let placeholder = AttentionKind.permissionRequest(tool: "", input: [:], toolUseId: "", interaction: .passive)
        let msg = makeMessage(event: "ToolPermission", toolName: "Read", toolUseId: "t2")
        let resolved = WireEventTranslator.resolvePermissionFields(placeholder, in: msg)
        if case .permissionRequest(_, _, _, let interaction) = resolved {
            XCTAssertEqual(interaction, .passive)
        } else {
            XCTFail("expected .permissionRequest, got \(resolved)")
        }
    }

    func test_resolvePermission_nonPermissionUnchanged() {
        let kind = AttentionKind.activityPulse
        let msg = makeMessage(event: "Stop")
        XCTAssertEqual(WireEventTranslator.resolvePermissionFields(kind, in: msg), kind)
    }

    func test_resolvePermission_handlesNilToolFieldsAsEmpty() {
        let placeholder = AttentionKind.permissionRequest(tool: "", input: [:], toolUseId: "", interaction: .actionable)
        let msg = makeMessage(event: "PermissionRequest", toolName: nil, toolInput: nil, toolUseId: nil)
        let resolved = WireEventTranslator.resolvePermissionFields(placeholder, in: msg)
        if case .permissionRequest(let tool, let input, let toolUseId, _) = resolved {
            XCTAssertEqual(tool, "")
            XCTAssertTrue(input.isEmpty)
            XCTAssertEqual(toolUseId, "")
        } else {
            XCTFail("expected .permissionRequest, got \(resolved)")
        }
    }

    // MARK: - makeEvent (field-mapping spot check)

    func test_makeEvent_copiesCoreFields() {
        let msg = makeMessage(
            event: "PreToolUse",
            sessionId: "s1",
            toolName: "Read",
            toolUseId: "t1",
            promptText: "Hi",
            commentaryText: "Reasoning",
            commentaryTimestamp: "2026-04-24T10:42:56Z"
        )
        let event = WireEventTranslator.makeEvent(
            from: msg,
            provider: .claude,
            kind: .activityPulse,
            pending: nil
        )
        XCTAssertEqual(event.provider, .claude)
        XCTAssertEqual(event.rawEventName, "PreToolUse")
        XCTAssertEqual(event.sessionId, "s1")
        XCTAssertEqual(event.toolName, "Read")
        XCTAssertEqual(event.toolUseId, "t1")
        XCTAssertEqual(event.promptText, "Hi")
        XCTAssertEqual(event.commentaryText, "Reasoning")
        XCTAssertNotNil(event.commentaryAt)
        XCTAssertEqual(event.kind, .activityPulse)
    }

    func test_makeEvent_emptySessionIdWhenNil() {
        let msg = makeMessage(event: "PreToolUse", sessionId: nil)
        let event = WireEventTranslator.makeEvent(
            from: msg,
            provider: .claude,
            kind: .activityPulse,
            pending: nil
        )
        XCTAssertEqual(event.sessionId, "")
    }

    func test_makeEvent_invalidTimestampDoesNotCrash() {
        let msg = makeMessage(
            event: "PreToolUse",
            commentaryTimestamp: "garbage"
        )
        let event = WireEventTranslator.makeEvent(
            from: msg,
            provider: .claude,
            kind: .activityPulse,
            pending: nil
        )
        XCTAssertNil(event.commentaryAt)
    }

    // MARK: - helper

    private func makeMessage(
        event: String,
        notificationType: String? = nil,
        provider: String? = nil,
        sessionId: String? = nil,
        toolName: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        toolUseId: String? = nil,
        promptText: String? = nil,
        commentaryText: String? = nil,
        commentaryTimestamp: String? = nil
    ) -> WireMessage {
        WireMessage(
            v: nil,
            auth_token: nil,
            provider: provider,
            event: event,
            status: nil,
            notification_type: notificationType,
            session_id: sessionId,
            cwd: nil,
            transcript_path: nil,
            pid: nil,
            tty: nil,
            terminal_name: nil,
            terminal_socket: nil,
            terminal_window_id: nil,
            terminal_tab_id: nil,
            terminal_surface_id: nil,
            tool_name: toolName,
            tool_input: toolInput,
            tool_use_id: toolUseId,
            tool_response: nil,
            message: nil,
            prompt_text: promptText,
            commentary_text: commentaryText,
            commentary_timestamp: commentaryTimestamp,
            expects_response: nil,
            timeout_ms: nil
        )
    }
}
