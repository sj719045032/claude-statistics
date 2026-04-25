import Foundation

extension HookRunner {
    func buildCodexAction(payload: [String: Any]) -> HookAction? {
        guard let event = payload["hook_event_name"] as? String else { return nil }
        let relayedEvents: Set<String> = [
            "SessionStart",
            "SessionEnd",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "PostToolUseFailure",
            "Notification",
            "SubagentStart",
            "SubagentStop",
            "PreCompact",
            "PostCompact",
            "StopFailure",
            "Stop",
        ]
        guard relayedEvents.contains(event) else { return nil }

        let terminalName = canonicalTerminalName(
            ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ProcessInfo.processInfo.environment["TERM"]
        )
        let cwd = resolvedHookCWD(payload: payload)
        let terminalContext = terminalContextForCodex(event: event, terminalName: terminalName, cwd: cwd)
        let tool = normalizeCodexTool(payload: payload)
        let toolUseId = normalizedToolUseId(payload: payload, toolInput: tool.input)

        let status: String
        switch event {
        case "PermissionRequest":
            status = "waiting_for_approval"
        case "Notification":
            if stringValue(payload["notification_type"]) == "idle_prompt" {
                status = "waiting_for_input"
            } else {
                status = "notification"
            }
        case "SessionStart", "Stop":
            status = "waiting_for_input"
        case "SessionEnd":
            status = "ended"
        case "StopFailure":
            status = "failed"
        case "PreCompact":
            status = "compacting"
        case "PreToolUse":
            status = "running_tool"
        default:
            status = "processing"
        }

        let normalizedMessage = codexMessage(payload: payload, event: event)

        var message: [String: Any] = baseMessage(
            provider: .codex,
            event: event,
            status: status,
            notificationType: nil,
            payload: payload,
            cwd: cwd,
            terminalName: terminalName,
            terminalContext: terminalContext
        )
        set(&message, "tool_name", tool.name)
        set(&message, "tool_input", tool.input)
        set(&message, "tool_use_id", toolUseId ?? stringValue(payload["turn_id"]))
        // Route normalizedMessage into the right semantic lane so downstream
        // livePrompt / liveProgressNote / livePreview can pick without guessing.
        switch event {
        case "UserPromptSubmit":
            set(&message, "prompt_text", normalizedMessage)
        case "Notification", "PermissionRequest", "ToolPermission", "SessionStart", "SessionEnd":
            set(&message, "message", normalizedMessage)
        default:
            set(&message, "commentary_text", normalizedMessage)
        }
        set(&message, "expects_response", event == "PermissionRequest")
        set(&message, "timeout_ms", event == "PermissionRequest" ? HookDefaults.approvalTimeoutMs : nil)

        logCodexPayloadDiagnosticsIfNeeded(
            payload: payload,
            event: event,
            toolName: tool.name,
            toolUseId: toolUseId,
            normalizedMessage: normalizedMessage
        )

        if ["PostToolUse", "PostToolUseFailure"].contains(event),
           let response = toolResponseText(payload: payload) {
            set(&message, "tool_response", String(response.prefix(HookDefaults.maxToolResponseLength)))
        }

        if event == "PermissionRequest" {
            return HookAction(
                message: message,
                expectsResponse: true,
                responseTimeoutSeconds: HookDefaults.approvalResponseTimeoutSeconds,
                printDecision: printCodexPermissionDecision
            )
        }

        return HookAction(message: message)
    }
}

private func logCodexPayloadDiagnosticsIfNeeded(
    payload: [String: Any],
    event: String,
    toolName: String?,
    toolUseId: String?,
    normalizedMessage: String?
) {
    guard normalizedMessage == nil,
          ["PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure"].contains(event) else {
        return
    }

    let keys = payload.keys.sorted().joined(separator: ",")
    let candidateKeys = [
        "message",
        "reason",
        "warning",
        "summary",
        "content",
        "last_assistant_message",
        "output",
        "response",
        "result",
        "resultDisplay",
        "tool_response",
        "tool_result",
        "error",
        "prompt",
        "source",
        "turn_id",
    ]

    let candidates = candidateKeys.compactMap { key -> String? in
        guard let value = payload[key],
              let text = firstText(value) else {
            return nil
        }
        let compact = text.replacingOccurrences(of: "\n", with: "\\n")
        return "\(key)=\(String(compact.prefix(120)))"
    }

    DiagnosticLogger.shared.verbose(
        "Codex raw payload diag event=\(event) tool=\(toolName ?? "-") toolUseId=\(toolUseId ?? "-") keys=[\(keys)] candidates=[\(candidates.joined(separator: " | "))]"
    )
}

private func codexMessage(payload: [String: Any], event: String) -> String? {
    switch event {
    case "UserPromptSubmit":
        return firstText(payload["prompt"])
    case "SessionStart":
        return firstText(payload["source"])
    case "Stop":
        return firstText(payload["last_assistant_message"])
            ?? firstText(payload["message"])
            ?? firstText(payload["reason"])
            ?? firstText(payload["prompt"])
            ?? firstText(payload["warning"])
    case "Notification":
        return firstText(payload["message"])
    case "StopFailure":
        return firstText(payload["error"])
            ?? firstText(payload["message"])
            ?? firstText(payload["reason"])
    default:
        return firstText(payload["message"])
            ?? firstText(payload["reason"])
            ?? firstText(payload["warning"])
    }
}

private func normalizeCodexTool(payload: [String: Any]) -> (name: String?, input: [String: Any]?) {
    let toolName = stringValue(payload["tool_name"])
    if let input = dictionaryValue(payload["tool_input"]) {
        return (toolName, input)
    }

    if let command = stringValue(payload["tool_input"]) ?? stringValue(payload["command"]) {
        return (toolName, ["command": command])
    }

    return (toolName, nil)
}
