import Foundation

extension HookRunner {
    func buildClaudeAction(payload: [String: Any]) -> HookAction? {
        guard let event = payload["hook_event_name"] as? String else { return nil }
        let relayedEvents: Set<String> = [
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PostToolUseFailure",
            "PermissionRequest",
            "Notification",
            "Stop",
            "SessionEnd",
            "SubagentStart",
            "SubagentStop",
            "StopFailure",
            "SessionStart",
            "PreCompact",
            "PostCompact",
        ]
        guard relayedEvents.contains(event) else { return nil }

        let notificationType = stringValue(payload["notification_type"])

        // Claude Code fires a Notification/permission_prompt toast alongside
        // the real PermissionRequest. It carries no info PermissionRequest
        // doesn't already have, so dropping it at the source avoids a useless
        // IPC round-trip and keeps the downstream timeline clean.
        if event == "Notification", notificationType == "permission_prompt" {
            return nil
        }

        let terminalName = canonicalTerminalName(
            ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ProcessInfo.processInfo.environment["TERM"]
        )
        let cwd = resolvedHookCWD(payload: payload)
        let terminalContext = terminalContextForClaude(event: event, terminalName: terminalName, cwd: cwd)

        let status: String
        switch event {
        case "PermissionRequest":
            status = "waiting_for_approval"
        case "Notification":
            if notificationType == "idle_prompt" {
                status = "waiting_for_input"
            } else if notificationType == "permission_prompt" {
                status = "processing"
            } else {
                status = "notification"
            }
        case "Stop", "StopFailure", "SessionStart":
            status = "waiting_for_input"
        case "SessionEnd":
            status = "ended"
        case "PreCompact":
            status = "compacting"
        case "PreToolUse":
            status = "running_tool"
        default:
            status = "processing"
        }

        var message: [String: Any] = baseMessage(
            provider: .claude,
            event: event,
            status: status,
            notificationType: notificationType,
            payload: payload,
            cwd: cwd,
            terminalName: terminalName,
            terminalContext: terminalContext
        )
        // Claude Code's hook payload does NOT include `last_assistant_message`
        // (we checked — every Bridge rx Bash log shows msgLen=0). The live
        // commentary lives in the transcript_path jsonl, so when the payload
        // keys come up empty, read the tail of that file to pull the most
        // recent assistant text block. This is what lets the supporting line
        // show "Claude said X" instead of being stuck on time-ago fallback.
        // Per-event, per-semantic-lane routing. Each event writes EXACTLY
        // ONE lane so downstream consumers (livePrompt / liveProgressNote /
        // livePreview) can't accidentally pick up the wrong payload:
        //
        //   prompt_text  (A) — user's typed prompt. UserPromptSubmit ONLY.
        //   commentary_text + commentary_timestamp (B) — Claude's assistant
        //     text from the transcript tail-scan. Any event that can carry
        //     commentary (PreToolUse / PostToolUse / Stop / StopFailure /
        //     PreCompact / PostCompact / Subagent* / SessionStart).
        //   message      (C/D) — status string ("Waiting for your input")
        //     or tool command description. Notification / PermissionRequest
        //     / ToolPermission.
        switch event {
        case "UserPromptSubmit":
            if let preview = claudePreview(payload: payload) {
                set(&message, "prompt_text", preview)
            }
        case "PermissionRequest", "ToolPermission":
            if let preview = claudePreview(payload: payload) {
                set(&message, "message", preview)
            }
        case "Notification":
            if let preview = claudePreview(payload: payload) {
                set(&message, "message", preview)
            }
        case "SessionEnd":
            break
        default:
            // Stop / StopFailure / PreToolUse / PostToolUse / PostToolUseFailure /
            // SessionStart / PreCompact / PostCompact / SubagentStart / SubagentStop.
            if let extracted = lastAssistantTextFromTranscript(payload: payload) {
                set(&message, "commentary_text", extracted.text)
                set(&message, "commentary_timestamp", extracted.timestamp)
            } else if let preview = claudePreview(payload: payload) {
                // Fallback for sessions without a transcript yet (e.g. the very
                // first hook on a fresh session): use whatever the payload
                // gave us as commentary.
                set(&message, "commentary_text", preview)
            }
        }

        if ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"].contains(event) {
            set(&message, "tool_name", stringValue(payload["tool_name"]))
            let toolInput = dictionaryValue(payload["tool_input"])
            set(&message, "tool_input", toolInput)
            set(&message, "tool_use_id", normalizedToolUseId(payload: payload, toolInput: toolInput))
        }

        if ["PostToolUse", "PostToolUseFailure"].contains(event),
           let response = toolResponseText(payload: payload) {
            set(&message, "tool_response", String(response.prefix(HookDefaults.maxToolResponseLength)))
        }

        if event == "PermissionRequest" {
            set(&message, "expects_response", true)
            set(&message, "timeout_ms", HookDefaults.approvalTimeoutMs)
            return HookAction(
                message: message,
                expectsResponse: true,
                responseTimeoutSeconds: HookDefaults.approvalResponseTimeoutSeconds,
                printDecision: printClaudePermissionDecision
            )
        }

        return HookAction(message: message)
    }
}

private func claudePreview(payload: [String: Any]) -> String? {
    for key in [
        "last_assistant_message",
        "message",
        "reason",
        "prompt",
        "warning",
        "error",
        "summary",
        "content",
        "hookSpecificOutput",
    ] {
        if let text = firstText(payload[key]) {
            return text
        }
    }
    return nil
}

/// Tail-read the transcript jsonl and return the most recent assistant text
/// block along with the transcript entry's original timestamp.
///
/// Assistant text entries are sparse: tool_use / tool_result / thinking
/// blocks can push a text entry hundreds of KB back from EOF (measured on a
/// real 17 MB session: 1st text is 3.9 KB away, 2nd is 13 KB, 3rd is 47 KB,
/// 4th jumps to 730 KB). A fixed window is always wrong, so we grow the
/// read exponentially (64 KB → 128 → 256 → … up to 8 MB) until a text
/// entry is found or the file is exhausted. Reading 17 MB costs ~tens of
/// ms but only happens when the recent turn really is tool-heavy.
private func lastAssistantTextFromTranscript(payload: [String: Any]) -> (text: String, timestamp: String?)? {
    guard let rawPath = stringValue(payload["transcript_path"]), !rawPath.isEmpty else { return nil }
    let path = (rawPath as NSString).expandingTildeInPath
    guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? fh.close() }

    guard let total = try? fh.seekToEnd(), total > 0 else { return nil }

    var window: UInt64 = 64 * 1024
    let cap: UInt64 = 8 * 1024 * 1024

    while true {
        let readSize = min(window, total)
        let offset = total - readSize
        do { try fh.seek(toOffset: offset) } catch { return nil }
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Drop the first (probably partial) line when we didn't read from 0
        // — a jsonl parse on half an object would just fail, but skipping
        // is tidier. At offset == 0 every line is complete.
        var lines = text.components(separatedBy: "\n")
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }

            let textBlocks = content.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let t = block["text"] as? String else { return nil }
                let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
            guard !textBlocks.isEmpty else { continue }
            let entryTimestamp = obj["timestamp"] as? String
            return (textBlocks.joined(separator: "\n"), entryTimestamp)
        }

        // No hit in this window. If we've already read the whole file or
        // hit the safety cap, give up. Otherwise double and try again.
        if readSize >= total || window >= cap { return nil }
        window = min(window * 2, cap)
    }
}
