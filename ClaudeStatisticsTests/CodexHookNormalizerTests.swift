import XCTest

@testable import Claude_Statistics

/// Coverage for `HookRunner.buildCodexAction(payload:)` — same shape as
/// `ClaudeHookNormalizerTests` but with Codex-specific quirks:
///   - No notification_type sub-routing (Codex only uses idle_prompt).
///   - SessionStart/SessionEnd are routed into `message`, not commentary.
///   - tool_use_id falls back to `turn_id` when normalizedToolUseId
///     can't extract one.
///   - tool_input may arrive as a bare string command instead of a
///     dict (the normalizer wraps it).
@MainActor
final class CodexHookNormalizerTests: XCTestCase {
    private let runner = HookRunner(provider: .codex)

    private func payload(
        event: String,
        sessionId: String = "s1",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var p: [String: Any] = [
            "hook_event_name": event,
            "session_id": sessionId,
        ]
        for (k, v) in extra { p[k] = v }
        return p
    }

    // MARK: - Event filtering

    func test_unknownEvent_returnsNil() {
        XCTAssertNil(runner.buildCodexAction(payload: payload(event: "Bogus")))
    }

    func test_missingEventName_returnsNil() {
        XCTAssertNil(runner.buildCodexAction(payload: ["session_id": "s1"]))
    }

    // MARK: - Status mapping

    func test_status_permissionRequest() {
        let a = runner.buildCodexAction(payload: payload(event: "PermissionRequest"))
        XCTAssertEqual(a?.message["status"] as? String, "waiting_for_approval")
    }

    func test_status_notificationIdlePrompt() {
        let a = runner.buildCodexAction(payload: payload(event: "Notification", extra: ["notification_type": "idle_prompt"]))
        XCTAssertEqual(a?.message["status"] as? String, "waiting_for_input")
    }

    func test_status_notificationOther() {
        let a = runner.buildCodexAction(payload: payload(event: "Notification", extra: ["notification_type": "anything_else"]))
        XCTAssertEqual(a?.message["status"] as? String, "notification")
    }

    func test_status_sessionStart_isWaitingForInput() {
        let a = runner.buildCodexAction(payload: payload(event: "SessionStart"))
        XCTAssertEqual(a?.message["status"] as? String, "waiting_for_input")
    }

    func test_status_stop_isWaitingForInput() {
        let a = runner.buildCodexAction(payload: payload(event: "Stop"))
        XCTAssertEqual(a?.message["status"] as? String, "waiting_for_input")
    }

    func test_status_sessionEnd_isEnded() {
        let a = runner.buildCodexAction(payload: payload(event: "SessionEnd"))
        XCTAssertEqual(a?.message["status"] as? String, "ended")
    }

    func test_status_stopFailure_isFailed() {
        let a = runner.buildCodexAction(payload: payload(event: "StopFailure"))
        XCTAssertEqual(a?.message["status"] as? String, "failed")
    }

    func test_status_preCompact_isCompacting() {
        let a = runner.buildCodexAction(payload: payload(event: "PreCompact"))
        XCTAssertEqual(a?.message["status"] as? String, "compacting")
    }

    func test_status_preToolUse_isRunningTool() {
        let a = runner.buildCodexAction(payload: payload(event: "PreToolUse", extra: [
            "tool_name": "exec_command",
            "tool_input": ["command": "ls"],
        ]))
        XCTAssertEqual(a?.message["status"] as? String, "running_tool")
    }

    // MARK: - Preview routing

    func test_userPromptSubmit_routesPromptIntoPromptText() {
        let a = runner.buildCodexAction(payload: payload(event: "UserPromptSubmit", extra: ["prompt": "hi"]))
        XCTAssertEqual(a?.message["prompt_text"] as? String, "hi")
        XCTAssertNil(a?.message["message"])
        XCTAssertNil(a?.message["commentary_text"])
    }

    func test_notification_routesIntoMessage() {
        let a = runner.buildCodexAction(payload: payload(event: "Notification", extra: ["message": "halt"]))
        XCTAssertEqual(a?.message["message"] as? String, "halt")
    }

    func test_sessionStart_routesSourceIntoMessage() {
        // Codex SessionStart's "preview" comes from the `source` key.
        let a = runner.buildCodexAction(payload: payload(event: "SessionStart", extra: ["source": "resume"]))
        XCTAssertEqual(a?.message["message"] as? String, "resume")
    }

    func test_sessionEnd_routesIntoMessage() {
        // SessionEnd is in the message-routing branch (not the commentary
        // fallback). Codex's normalizer only writes it if codexMessage
        // returns non-nil — for SessionEnd, the default branch picks up
        // payload.message / reason / warning.
        let a = runner.buildCodexAction(payload: payload(event: "SessionEnd", extra: ["message": "bye"]))
        XCTAssertEqual(a?.message["message"] as? String, "bye")
    }

    func test_stop_prefersLastAssistantMessage() {
        let a = runner.buildCodexAction(payload: payload(event: "Stop", extra: [
            "last_assistant_message": "primary",
            "message": "fallback",
        ]))
        XCTAssertEqual(a?.message["commentary_text"] as? String, "primary")
    }

    func test_stop_fallsThroughToMessage() {
        let a = runner.buildCodexAction(payload: payload(event: "Stop", extra: ["message": "fallback"]))
        XCTAssertEqual(a?.message["commentary_text"] as? String, "fallback")
    }

    func test_stopFailure_prefersErrorOverMessage() {
        let a = runner.buildCodexAction(payload: payload(event: "StopFailure", extra: [
            "error": "Boom",
            "message": "ignored",
        ]))
        XCTAssertEqual(a?.message["commentary_text"] as? String, "Boom")
    }

    // MARK: - Tool input normalization

    func test_toolInput_dictionaryPassesThrough() {
        let a = runner.buildCodexAction(payload: payload(event: "PreToolUse", extra: [
            "tool_name": "exec_command",
            "tool_input": ["command": "echo hi", "cwd": "/tmp"],
        ]))
        let input = a?.message["tool_input"] as? [String: Any]
        XCTAssertEqual(input?["command"] as? String, "echo hi")
        XCTAssertEqual(input?["cwd"] as? String, "/tmp")
    }

    func test_toolInput_bareStringIsWrappedAsCommand() {
        // Some Codex variants emit `tool_input: "ls -la"` (a string, not
        // a dict). normalizeCodexTool wraps it under {command: "..."}.
        let a = runner.buildCodexAction(payload: payload(event: "PreToolUse", extra: [
            "tool_name": "exec_command",
            "tool_input": "ls -la",
        ]))
        let input = a?.message["tool_input"] as? [String: Any]
        XCTAssertEqual(input?["command"] as? String, "ls -la")
    }

    func test_toolInput_topLevelCommand_wrapped() {
        // No tool_input at all, but a top-level `command` field. Used by
        // older Codex releases.
        let a = runner.buildCodexAction(payload: payload(event: "PreToolUse", extra: [
            "tool_name": "exec_command",
            "command": "uname",
        ]))
        let input = a?.message["tool_input"] as? [String: Any]
        XCTAssertEqual(input?["command"] as? String, "uname")
    }

    // MARK: - tool_use_id fallback

    func test_toolUseId_fallsBackToTurnId() {
        // No id in tool_input → use payload.turn_id.
        let a = runner.buildCodexAction(payload: payload(event: "PreToolUse", extra: [
            "tool_name": "exec_command",
            "tool_input": ["command": "ls"],
            "turn_id": "turn-42",
        ]))
        XCTAssertEqual(a?.message["tool_use_id"] as? String, "turn-42")
    }

    // MARK: - PermissionRequest handshake

    func test_permissionRequest_setsExpectsResponseAndTimeout() {
        let a = runner.buildCodexAction(payload: payload(event: "PermissionRequest", extra: [
            "tool_name": "apply_patch",
            "tool_input": ["patch": "diff..."],
        ]))
        XCTAssertEqual(a?.expectsResponse, true)
        XCTAssertEqual(a?.message["expects_response"] as? Bool, true)
        XCTAssertEqual(a?.message["timeout_ms"] as? Int, HookDefaults.approvalTimeoutMs)
    }

    func test_nonPermission_isFireAndForget() {
        let a = runner.buildCodexAction(payload: payload(event: "Stop"))
        XCTAssertEqual(a?.expectsResponse, false)
        XCTAssertEqual(a?.message["expects_response"] as? Bool, false)
        // Non-permission events must NOT carry timeout_ms (downstream
        // treats its presence as a permission-flow signal).
        XCTAssertNil(a?.message["timeout_ms"])
    }

    // MARK: - tool_response

    func test_postToolUse_includesToolResponse() {
        let a = runner.buildCodexAction(payload: payload(event: "PostToolUse", extra: [
            "tool_name": "exec_command",
            "tool_input": ["command": "echo ok"],
            "tool_response": "ok",
        ]))
        XCTAssertEqual(a?.message["tool_response"] as? String, "ok")
    }
}
