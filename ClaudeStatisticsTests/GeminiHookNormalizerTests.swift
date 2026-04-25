import XCTest

@testable import Claude_Statistics

/// Coverage for `HookRunner.buildGeminiAction(payload:)` — Gemini's
/// hooks differ structurally from Claude/Codex:
///   - Hook event names are remapped to wire events (BeforeAgent →
///     UserPromptSubmit, BeforeTool → PreToolUse, AfterAgent → Stop).
///   - `Notification` with notification_type=ToolPermission becomes
///     wire event `ToolPermission` (passive permission card lane).
///   - `tool_input` may arrive as a JSON string and gets re-parsed.
///   - Session id arrives as camelCase `sessionId`.
///   - tool_response is a structured object with `returnDisplay` /
///     `llmContent` / `error`.
final class GeminiHookNormalizerTests: XCTestCase {
    private let runner = HookRunner(provider: .gemini)

    private func payload(
        event: String,
        sessionId: String? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var p: [String: Any] = ["hook_event_name": event]
        // Gemini uses camelCase sessionId; baseMessage backfills from
        // there into snake_case session_id.
        if let sessionId { p["sessionId"] = sessionId }
        for (k, v) in extra { p[k] = v }
        return p
    }

    // MARK: - Event filtering

    func test_unknownEvent_returnsNil() {
        XCTAssertNil(runner.buildGeminiAction(payload: payload(event: "RandomEvent")))
    }

    func test_missingEventName_returnsNil() {
        XCTAssertNil(runner.buildGeminiAction(payload: ["foo": "bar"]))
    }

    // MARK: - Wire event remapping

    func test_beforeAgent_remapsToUserPromptSubmit() {
        let a = runner.buildGeminiAction(payload: payload(event: "BeforeAgent", extra: ["prompt": "hi"]))
        XCTAssertEqual(a?.message["event"] as? String, "UserPromptSubmit")
    }

    func test_beforeTool_remapsToPreToolUse() {
        let a = runner.buildGeminiAction(payload: payload(event: "BeforeTool", extra: [
            "tool_name": "run_shell_command",
            "tool_input": ["command": "ls"],
        ]))
        XCTAssertEqual(a?.message["event"] as? String, "PreToolUse")
    }

    func test_afterTool_remapsToPostToolUse() {
        let a = runner.buildGeminiAction(payload: payload(event: "AfterTool", extra: [
            "tool_name": "run_shell_command",
            "tool_input": ["command": "ls"],
        ]))
        XCTAssertEqual(a?.message["event"] as? String, "PostToolUse")
    }

    func test_afterAgent_remapsToStop() {
        let a = runner.buildGeminiAction(payload: payload(event: "AfterAgent"))
        XCTAssertEqual(a?.message["event"] as? String, "Stop")
    }

    func test_notification_toolPermission_remapsToToolPermission() {
        let a = runner.buildGeminiAction(payload: payload(event: "Notification", extra: [
            "notification_type": "ToolPermission",
            "message": "Allow rm?",
        ]))
        XCTAssertEqual(a?.message["event"] as? String, "ToolPermission")
        XCTAssertEqual(a?.message["status"] as? String, "waiting_for_approval")
    }

    func test_notification_other_staysAsNotification() {
        let a = runner.buildGeminiAction(payload: payload(event: "Notification", extra: [
            "notification_type": "info",
            "message": "x",
        ]))
        XCTAssertEqual(a?.message["event"] as? String, "Notification")
        XCTAssertEqual(a?.message["status"] as? String, "notification")
    }

    func test_passThroughEvents_keepNames() {
        for evt in ["BeforeToolSelection", "BeforeModel", "AfterModel", "SessionStart", "SessionEnd", "PreCompress"] {
            let a = runner.buildGeminiAction(payload: payload(event: evt))
            XCTAssertEqual(a?.message["event"] as? String, evt, "\(evt) must pass through")
        }
    }

    // MARK: - Status mapping (key cases)

    func test_status_sessionStart() {
        let a = runner.buildGeminiAction(payload: payload(event: "SessionStart"))
        XCTAssertEqual(a?.message["status"] as? String, "waiting_for_input")
    }

    func test_status_afterAgent() {
        let a = runner.buildGeminiAction(payload: payload(event: "AfterAgent"))
        XCTAssertEqual(a?.message["status"] as? String, "waiting_for_input")
    }

    func test_status_sessionEnd() {
        let a = runner.buildGeminiAction(payload: payload(event: "SessionEnd"))
        XCTAssertEqual(a?.message["status"] as? String, "ended")
    }

    func test_status_preCompress() {
        let a = runner.buildGeminiAction(payload: payload(event: "PreCompress"))
        XCTAssertEqual(a?.message["status"] as? String, "compacting")
    }

    func test_status_beforeTool() {
        let a = runner.buildGeminiAction(payload: payload(event: "BeforeTool", extra: [
            "tool_name": "run_shell_command",
            "tool_input": ["command": "ls"],
        ]))
        XCTAssertEqual(a?.message["status"] as? String, "running_tool")
    }

    // MARK: - Session ID camelCase backfill

    func test_camelCaseSessionId_backfillsToSnakeCase() {
        let a = runner.buildGeminiAction(payload: payload(event: "SessionStart", sessionId: "g-abc"))
        XCTAssertEqual(a?.message["session_id"] as? String, "g-abc")
    }

    // MARK: - Preview routing

    func test_beforeAgent_routesPromptIntoPromptText() {
        let a = runner.buildGeminiAction(payload: payload(event: "BeforeAgent", extra: ["prompt": "hello"]))
        XCTAssertEqual(a?.message["prompt_text"] as? String, "hello")
    }

    func test_sessionStart_routesSourceIntoMessage() {
        let a = runner.buildGeminiAction(payload: payload(event: "SessionStart", extra: ["source": "resume"]))
        XCTAssertEqual(a?.message["message"] as? String, "resume")
    }

    func test_sessionEnd_routesReasonIntoMessage() {
        let a = runner.buildGeminiAction(payload: payload(event: "SessionEnd", extra: ["reason": "logout"]))
        XCTAssertEqual(a?.message["message"] as? String, "logout")
    }

    func test_afterAgent_prefersPromptResponseAsCommentary() {
        // No transcript_path → falls back to prompt_response.
        let a = runner.buildGeminiAction(payload: payload(event: "AfterAgent", extra: ["prompt_response": "Done."]))
        XCTAssertEqual(a?.message["commentary_text"] as? String, "Done.")
    }

    // MARK: - Tool input normalization

    func test_toolInput_dictPassesThrough() {
        let a = runner.buildGeminiAction(payload: payload(event: "BeforeTool", extra: [
            "tool_name": "run_shell_command",
            "tool_input": ["command": "ls", "cwd": "/tmp"],
        ]))
        let input = a?.message["tool_input"] as? [String: Any]
        XCTAssertEqual(input?["command"] as? String, "ls")
    }

    func test_toolInput_jsonStringIsParsed() {
        // Some Gemini hook variants pass tool_input as a JSON string —
        // normalizeGeminiToolInput parses it back to a dict.
        let a = runner.buildGeminiAction(payload: payload(event: "BeforeTool", extra: [
            "tool_name": "read_file",
            "tool_input": #"{"path": "/etc/hosts"}"#,
        ]))
        let input = a?.message["tool_input"] as? [String: Any]
        XCTAssertEqual(input?["path"] as? String, "/etc/hosts")
    }

    func test_toolInput_fallsBackToArgsKey() {
        // Older Gemini payloads use `args` instead of `tool_input`.
        let a = runner.buildGeminiAction(payload: payload(event: "BeforeTool", extra: [
            "tool_name": "read_file",
            "args": ["path": "/etc/passwd"],
        ]))
        let input = a?.message["tool_input"] as? [String: Any]
        XCTAssertEqual(input?["path"] as? String, "/etc/passwd")
    }

    // MARK: - Tool response (structured object)

    func test_afterTool_prefersReturnDisplay() {
        let a = runner.buildGeminiAction(payload: payload(event: "AfterTool", extra: [
            "tool_name": "run_shell_command",
            "tool_input": ["command": "ls"],
            "tool_response": [
                "returnDisplay": "files...",
                "llmContent": "should be ignored",
                "error": "",
            ],
        ]))
        XCTAssertEqual(a?.message["tool_response"] as? String, "files...")
    }

    func test_afterTool_fallsBackToLlmContent() {
        let a = runner.buildGeminiAction(payload: payload(event: "AfterTool", extra: [
            "tool_name": "read_file",
            "tool_input": ["path": "/x"],
            "tool_response": ["llmContent": "the file contents"],
        ]))
        XCTAssertEqual(a?.message["tool_response"] as? String, "the file contents")
    }

    func test_afterTool_fallsBackToError() {
        let a = runner.buildGeminiAction(payload: payload(event: "AfterTool", extra: [
            "tool_name": "read_file",
            "tool_input": ["path": "/x"],
            "tool_response": ["error": "ENOENT"],
        ]))
        XCTAssertEqual(a?.message["tool_response"] as? String, "ENOENT")
    }

    // MARK: - Gemini does NOT use expects_response handshake

    func test_geminiToolPermission_doesNotSetExpectsResponse() {
        // Gemini's permission cards are passive — the CLI doesn't wait
        // for the app's decision; the user has to confirm in the
        // terminal directly. We must NOT set expects_response or the
        // hook will block forever.
        let a = runner.buildGeminiAction(payload: payload(event: "Notification", extra: [
            "notification_type": "ToolPermission",
            "message": "Allow x?",
        ]))
        XCTAssertEqual(a?.expectsResponse, false)
        XCTAssertEqual(a?.message["expects_response"] as? Bool, false)
    }
}
