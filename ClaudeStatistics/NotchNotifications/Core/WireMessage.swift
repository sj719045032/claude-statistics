import Foundation

/// JSON wire protocol between the hook CLI and the in-app `AttentionBridge`.
/// Each connection sends one of these as a single line of JSON, then waits
/// up to `timeout_ms` for a `{decision: allow|deny|ask}` reply when
/// `expects_response == true`.
///
/// Internal (not `private`) because `WireEventTranslator` and tests both
/// reference it; production use is still confined to `AttentionBridge` and
/// `WireEventTranslator`.
struct WireMessage: Decodable {
    let v: Int?
    let auth_token: String?
    let provider: String?
    let event: String
    let status: String?
    let notification_type: String?
    let session_id: String?
    let cwd: String?
    let transcript_path: String?
    let pid: Int?
    let tty: String?
    let terminal_name: String?
    let terminal_socket: String?
    let terminal_window_id: String?
    let terminal_tab_id: String?
    let terminal_surface_id: String?
    /// `__CFBundleIdentifier` from the hook's process env, transmitted
    /// raw by the hook CLI. The host resolves it against plugin
    /// descriptors' `bundleIdentifiers` to recognise chat-app GUI hosts
    /// (Claude.app, Codex.app, etc.) regardless of what the user shell
    /// rc happened to leak into TERM/TERM_PROGRAM. The hook CLI does
    /// no plugin-aware lookup — it's a dumb pipe.
    let host_app_bundle_id: String?
    /// Subset of the hook's process env relevant to terminal
    /// identification, transmitted raw. The host walks every
    /// `TerminalEnvIdentifying` plugin against this dictionary to
    /// pick the right terminal and pull socket / surface / window /
    /// tab ids out without hardcoding any env-var name in host code.
    let terminal_env: [String: String]?
    let tool_name: String?
    let tool_input: [String: JSONValue]?
    let tool_use_id: String?
    let tool_response: String?
    /// Status string / tool command description (semantic C and D). Read by
    /// AttentionEvent.livePreview (.waitingInput / .taskDone / .taskFailed)
    /// and by PermissionRequestCard. NOT read as prompt or commentary.
    let message: String?
    /// The user's typed prompt. Only UserPromptSubmit writes this. Consumed
    /// by AttentionEvent.livePrompt. (Semantic A)
    let prompt_text: String?
    /// Claude's assistant text — the actual agent commentary. Any event whose
    /// normalizer can read it from the transcript writes it here. Consumed
    /// by AttentionEvent.liveProgressNote. (Semantic B)
    let commentary_text: String?
    /// ISO-8601 of the transcript entry that produced `commentary_text`, so
    /// downstream can place `latestProgressNoteAt` at when the text was
    /// actually written, not when the hook fired.
    let commentary_timestamp: String?
    let expects_response: Bool?
    let timeout_ms: Int?
}
