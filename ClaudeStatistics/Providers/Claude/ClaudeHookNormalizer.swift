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
        set(&message, "message", claudePreview(payload: payload))

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
