import XCTest

@testable import Claude_Statistics

/// Coverage for `HookRunner.buildClaudeAction(payload:)` — the layer that
/// turns a raw Claude Code hook JSON payload into a typed `HookAction`
/// the Bridge can consume. Tests focus on:
///   1. Event filtering (unknown events → nil, special-case
///      `Notification/permission_prompt` → nil).
///   2. Status string mapping per event.
///   3. Per-event preview routing (prompt_text vs. message vs.
///      commentary_text).
///   4. PermissionRequest's special expects-response handshake fields.
///
/// We avoid touching transcript_path on disk by leaving that key out of
/// payloads — the `lastAssistantTextFromTranscript` early-returns when
/// the path is empty/missing and falls through to `claudePreview`.
final class ClaudeHookNormalizerTests: XCTestCase {
    private let runner = HookRunner(provider: .claude)

    private func payload(
        event: String,
        notificationType: String? = nil,
        sessionId: String = "s1",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var p: [String: Any] = [
            "hook_event_name": event,
            "session_id": sessionId,
        ]
        if let notificationType { p["notification_type"] = notificationType }
        for (k, v) in extra { p[k] = v }
        return p
    }

    // MARK: - Event filtering

    func test_missingEventName_returnsNil() {
        let action = runner.buildClaudeAction(payload: ["session_id": "s1"])
        XCTAssertNil(action)
    }

    func test_unknownEvent_returnsNil() {
        let action = runner.buildClaudeAction(payload: payload(event: "RandomEvent"))
        XCTAssertNil(action)
    }

    func test_notificationPermissionPrompt_returnsNil() {
        // Claude Code fires Notification/permission_prompt alongside the
        // real PermissionRequest. We drop it at source — duplicate IPC.
        let action = runner.buildClaudeAction(
            payload: payload(event: "Notification", notificationType: "permission_prompt")
        )
        XCTAssertNil(action, "Notification + permission_prompt must be dropped")
    }

    // MARK: - Status mapping

    func test_status_permissionRequest_isWaitingForApproval() {
        let action = runner.buildClaudeAction(payload: payload(event: "PermissionRequest"))
        XCTAssertEqual(action?.message["status"] as? String, "waiting_for_approval")
    }

    func test_status_notificationIdlePrompt_isWaitingForInput() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "Notification", notificationType: "idle_prompt")
        )
        XCTAssertEqual(action?.message["status"] as? String, "waiting_for_input")
    }

    func test_status_notificationOther_isNotification() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "Notification", notificationType: "something_else")
        )
        XCTAssertEqual(action?.message["status"] as? String, "notification")
    }

    func test_status_stop_isWaitingForInput() {
        let action = runner.buildClaudeAction(payload: payload(event: "Stop"))
        XCTAssertEqual(action?.message["status"] as? String, "waiting_for_input")
    }

    func test_status_sessionEnd_isEnded() {
        let action = runner.buildClaudeAction(payload: payload(event: "SessionEnd"))
        XCTAssertEqual(action?.message["status"] as? String, "ended")
    }

    func test_status_preCompact_isCompacting() {
        let action = runner.buildClaudeAction(payload: payload(event: "PreCompact"))
        XCTAssertEqual(action?.message["status"] as? String, "compacting")
    }

    func test_status_preToolUse_isRunningTool() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "PreToolUse", extra: [
                "tool_name": "Bash",
                "tool_input": ["command": "ls"],
            ])
        )
        XCTAssertEqual(action?.message["status"] as? String, "running_tool")
    }

    func test_status_postToolUse_defaultIsProcessing() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "PostToolUse", extra: [
                "tool_name": "Bash",
                "tool_input": ["command": "ls"],
            ])
        )
        XCTAssertEqual(action?.message["status"] as? String, "processing")
    }

    // MARK: - Preview routing

    func test_userPromptSubmit_routesPreviewIntoPromptText() {
        // UserPromptSubmit's preview must land in `prompt_text`, NOT
        // `message` or `commentary_text` — downstream lanes are strict.
        let action = runner.buildClaudeAction(
            payload: payload(event: "UserPromptSubmit", extra: ["prompt": "Hello world"])
        )
        XCTAssertEqual(action?.message["prompt_text"] as? String, "Hello world")
        XCTAssertNil(action?.message["message"], "UserPromptSubmit must NOT set message")
        XCTAssertNil(action?.message["commentary_text"], "UserPromptSubmit must NOT set commentary_text")
    }

    func test_permissionRequest_routesPreviewIntoMessage() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "PermissionRequest", extra: [
                "tool_name": "Bash",
                "tool_input": ["command": "rm -rf /"],
                "reason": "destructive command",
            ])
        )
        XCTAssertEqual(action?.message["message"] as? String, "destructive command")
        XCTAssertNil(action?.message["prompt_text"], "PermissionRequest must NOT set prompt_text")
    }

    func test_notificationFallback_routesPreviewIntoMessage() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "Notification", notificationType: "idle_prompt", extra: [
                "message": "Waiting for input",
            ])
        )
        XCTAssertEqual(action?.message["message"] as? String, "Waiting for input")
    }

    func test_otherEvent_withoutTranscript_routesIntoCommentaryFallback() {
        // No transcript_path, so lastAssistantTextFromTranscript returns
        // nil and we fall through to the claudePreview-as-commentary
        // branch.
        let action = runner.buildClaudeAction(
            payload: payload(event: "Stop", extra: ["last_assistant_message": "Done."])
        )
        XCTAssertEqual(action?.message["commentary_text"] as? String, "Done.")
    }

    func test_sessionEnd_doesNotPopulateAnyPreview() {
        // SessionEnd is the explicit "no preview" carve-out.
        let action = runner.buildClaudeAction(
            payload: payload(event: "SessionEnd", extra: ["last_assistant_message": "ignored"])
        )
        XCTAssertNotNil(action)
        XCTAssertNil(action?.message["prompt_text"])
        XCTAssertNil(action?.message["message"])
        XCTAssertNil(action?.message["commentary_text"])
    }

    // MARK: - Tool fields

    func test_preToolUse_populatesToolFields() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "PreToolUse", extra: [
                "tool_name": "Edit",
                "tool_input": ["file_path": "/tmp/x", "old_string": "a", "new_string": "b"],
            ])
        )
        XCTAssertEqual(action?.message["tool_name"] as? String, "Edit")
        let toolInput = action?.message["tool_input"] as? [String: Any]
        XCTAssertEqual(toolInput?["file_path"] as? String, "/tmp/x")
    }

    func test_postToolUse_includesToolResponse() {
        // `firstText` trims whitespace before returning, so the stored
        // value reflects post-trim content — `"hi\n"` becomes `"hi"`.
        let action = runner.buildClaudeAction(
            payload: payload(event: "PostToolUse", extra: [
                "tool_name": "Bash",
                "tool_input": ["command": "echo hi"],
                "tool_response": "hi\n",
            ])
        )
        XCTAssertEqual(action?.message["tool_response"] as? String, "hi")
    }

    func test_postToolUse_truncatesLongToolResponse() {
        let big = String(repeating: "a", count: HookDefaults.maxToolResponseLength + 100)
        let action = runner.buildClaudeAction(
            payload: payload(event: "PostToolUse", extra: [
                "tool_name": "Bash",
                "tool_input": ["command": "yes"],
                "tool_response": big,
            ])
        )
        let stored = action?.message["tool_response"] as? String
        XCTAssertEqual(stored?.count, HookDefaults.maxToolResponseLength)
    }

    // MARK: - PermissionRequest handshake fields

    func test_permissionRequest_setsExpectsResponseAndTimeout() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "PermissionRequest", extra: [
                "tool_name": "Bash",
                "tool_input": ["command": "ls"],
            ])
        )
        XCTAssertEqual(action?.expectsResponse, true)
        XCTAssertEqual(action?.message["expects_response"] as? Bool, true)
        XCTAssertEqual(action?.message["timeout_ms"] as? Int, HookDefaults.approvalTimeoutMs)
        XCTAssertEqual(action?.responseTimeoutSeconds, HookDefaults.approvalResponseTimeoutSeconds)
    }

    func test_nonPermissionEvent_isFireAndForget() {
        let action = runner.buildClaudeAction(
            payload: payload(event: "PreToolUse", extra: [
                "tool_name": "Read",
                "tool_input": ["file_path": "/etc/hosts"],
            ])
        )
        XCTAssertEqual(action?.expectsResponse, false)
        XCTAssertEqual(action?.message["expects_response"] as? Bool, false)
    }
}
