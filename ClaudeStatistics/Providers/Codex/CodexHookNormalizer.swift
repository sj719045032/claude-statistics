import Foundation

extension HookRunner {
    func buildCodexAction(payload: [String: Any]) -> HookAction? {
        guard let event = payload["hook_event_name"] as? String else { return nil }
        let relayedEvents: Set<String> = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
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
        case "SessionStart", "Stop":
            status = "waiting_for_input"
        case "PreToolUse":
            status = "running_tool"
        default:
            status = "processing"
        }

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
        set(&message, "message", codexMessage(payload: payload, event: event))
        set(&message, "expects_response", event == "PermissionRequest")
        set(&message, "timeout_ms", event == "PermissionRequest" ? HookDefaults.approvalTimeoutMs : nil)

        if event == "PostToolUse", let response = toolResponseText(payload: payload) {
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
