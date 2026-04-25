import Foundation

extension HookRunner {
    func buildGeminiAction(payload: [String: Any]) -> HookAction? {
        guard let event = payload["hook_event_name"] as? String else { return nil }
        let relayedEvents: Set<String> = [
            "BeforeAgent",
            "BeforeTool",
            "BeforeToolSelection",
            "BeforeModel",
            "AfterTool",
            "AfterModel",
            "AfterAgent",
            "SessionStart",
            "SessionEnd",
            "PreCompress",
            "Notification",
        ]
        guard relayedEvents.contains(event) else { return nil }

        let notificationType = stringValue(payload["notification_type"])
        let terminalName = canonicalTerminalName(
            ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ProcessInfo.processInfo.environment["TERM"]
        )
        let cwd = resolvedHookCWD(payload: payload)
        let terminalContext = terminalContextForGemini(event: event, terminalName: terminalName, cwd: cwd)

        // Map Gemini's hook_event_name to the wire event AttentionBridge
        // dispatches on. Notification + notification_type="ToolPermission"
        // gets its own wire event because passive permission cards have
        // their own lane downstream.
        var wireEvent: String
        var toolName: String?
        var toolInput: [String: Any]?
        var toolUseId: String?
        switch event {
        case "BeforeAgent":
            wireEvent = "UserPromptSubmit"
        case "BeforeTool":
            wireEvent = "PreToolUse"
            toolName = canonicalGeminiToolName(toolNameValue(payload))
            toolInput = normalizeGeminiToolInput(payload["tool_input"])
                ?? normalizeGeminiToolInput(payload["args"])
            toolUseId = normalizedToolUseId(payload: payload, toolInput: toolInput)
        case "AfterTool":
            wireEvent = "PostToolUse"
            toolName = canonicalGeminiToolName(toolNameValue(payload))
            toolInput = normalizeGeminiToolInput(payload["tool_input"])
                ?? normalizeGeminiToolInput(payload["args"])
            toolUseId = normalizedToolUseId(payload: payload, toolInput: toolInput)
        case "AfterAgent":
            wireEvent = "Stop"
        case "Notification":
            wireEvent = notificationType == "ToolPermission" ? "ToolPermission" : "Notification"
        default:
            // BeforeToolSelection / BeforeModel / AfterModel / SessionStart /
            // SessionEnd / PreCompress pass through under their own names.
            wireEvent = event
        }

        let status: String
        switch event {
        case "Notification":
            status = wireEvent == "ToolPermission" ? "waiting_for_approval" : "notification"
        case "SessionStart", "AfterAgent":
            status = "waiting_for_input"
        case "SessionEnd":
            status = "ended"
        case "PreCompress":
            status = "compacting"
        case "BeforeTool":
            status = "running_tool"
        default:
            status = "processing"
        }

        var message: [String: Any] = baseMessage(
            provider: .gemini,
            event: wireEvent,
            status: status,
            notificationType: notificationType,
            payload: payload,
            cwd: cwd,
            terminalName: terminalName,
            terminalContext: terminalContext
        )

        // Gemini hook payloads use camelCase `sessionId`; baseMessage only
        // reads snake_case `session_id`, so backfill here.
        if message["session_id"] == nil {
            set(&message, "session_id", stringValue(payload["sessionId"]))
        }
        set(&message, "tool_name", toolName)
        set(&message, "tool_input", toolInput)
        set(&message, "tool_use_id", toolUseId)

        // Per-event semantic-lane routing matches Codex/Claude so downstream
        // (livePrompt / liveProgressNote / livePreview) can pick the right
        // text without guessing.
        switch event {
        case "BeforeAgent":
            // Semantic A: the user's prompt.
            set(&message, "prompt_text", firstText(payload["prompt"]))

        case "Notification":
            // ToolPermission notification → tool/path summary for the card;
            // other notifications → status string.
            let text = firstText(payload["message"])
                ?? firstText(payload["details"])
                ?? firstText(payload["reason"])
            set(&message, "message", text)

        case "SessionStart":
            // `source` is "startup" | "resume" | "clear" per the docs.
            set(&message, "message", firstText(payload["source"]))

        case "SessionEnd":
            // `reason` is "exit" | "clear" | "logout" | "prompt_input_exit" | "other".
            set(&message, "message", firstText(payload["reason"]))

        case "AfterAgent":
            // The turn's final response. `prompt_response` is the documented
            // field per Gemini's hook reference; transcript tail-scan is a
            // fallback for older payload shapes.
            if let promptResponse = firstText(payload["prompt_response"]) {
                set(&message, "commentary_text", promptResponse)
            } else if let extracted = lastAssistantFromGeminiTranscript(payload: payload) {
                set(&message, "commentary_text", extracted.text)
                set(&message, "commentary_timestamp", extracted.timestamp)
            }

        case "AfterModel":
            // Streaming chunk-level — fires on every token batch. Writing
            // commentary_text here would clobber the field N times per turn
            // and the rendered text would only ever be the latest chunk
            // (likely a partial sentence). Mid-turn assistant text is read
            // from the transcript on the surrounding tool events instead.
            // We still relay the wire event so RuntimeSessionEventApplier
            // can clear the BeforeModel "thinking" indicator.
            break

        case "BeforeTool", "AfterTool", "BeforeModel", "BeforeToolSelection", "PreCompress":
            // No assistant text in these payloads — Gemini's hooks don't
            // expose per-message replies. Tail-scan the transcript for the
            // most recent `type: "gemini"` message so the notch bottom row
            // can show "Gemini said …" between tool calls. Same approach
            // as Claude's lastAssistantTextFromTranscript.
            if let extracted = lastAssistantFromGeminiTranscript(payload: payload) {
                set(&message, "commentary_text", extracted.text)
                set(&message, "commentary_timestamp", extracted.timestamp)
            }

        default:
            break
        }

        if event == "AfterTool",
           let response = geminiToolResponseText(payload: payload) {
            set(&message, "tool_response", String(response.prefix(HookDefaults.maxToolResponseLength)))
        }

        return HookAction(message: message)
    }

    private func canonicalGeminiToolName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return ProviderKind.gemini.canonicalToolName(raw)
    }

    private func normalizeGeminiToolInput(_ rawInput: Any?) -> [String: Any]? {
        guard let rawInput else { return nil }
        if let dict = rawInput as? [String: Any] { return dict }
        if let str = rawInput as? String,
           let data = str.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    /// Gemini's `tool_response` is an object with `llmContent` /
    /// `returnDisplay` / `error`, not a string. Prefer the human-readable
    /// `returnDisplay`, fall back to `llmContent`, then `error`.
    private func geminiToolResponseText(payload: [String: Any]) -> String? {
        guard let response = payload["tool_response"] as? [String: Any] else {
            return toolResponseText(payload: payload)
        }
        return firstText(response["returnDisplay"])
            ?? firstText(response["llmContent"])
            ?? firstText(response["error"])
    }

    /// Walk back from the end of the Gemini transcript JSON and return the
    /// most recent `type: "gemini"` message's content + timestamp. Gemini
    /// rewrites the entire transcript file on each save (not jsonl-append),
    /// so we just parse it in full instead of doing Claude's exponential
    /// tail-window scan.
    private func lastAssistantFromGeminiTranscript(payload: [String: Any]) -> (text: String, timestamp: String?)? {
        guard let rawPath = stringValue(payload["transcript_path"]), !rawPath.isEmpty else { return nil }
        let path = (rawPath as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return nil }

        for msg in messages.reversed() {
            guard let type = msg["type"] as? String, type == "gemini" else { continue }
            guard let text = extractGeminiTranscriptText(msg["content"]) else { continue }
            let timestamp = msg["timestamp"] as? String
            return (text, timestamp)
        }
        return nil
    }

    /// Gemini messages store content either as a plain string ("gemini"
    /// replies) or as `[{"text": "..."}]` (user prompts). Handle both so the
    /// same helper works regardless of which side wrote the message.
    private func extractGeminiTranscriptText(_ raw: Any?) -> String? {
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let parts = raw as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }
}
