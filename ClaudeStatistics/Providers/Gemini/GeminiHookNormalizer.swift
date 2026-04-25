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
            "ToolPermission",
        ]
        guard relayedEvents.contains(event) else { return nil }

        let notificationType = stringValue(payload["notification_type"])
        let terminalName = canonicalTerminalName(
            ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ProcessInfo.processInfo.environment["TERM"]
        )
        let cwd = resolvedHookCWD(payload: payload)
        let terminalContext = terminalContextForGemini(event: event, terminalName: terminalName, cwd: cwd)

        var wireEvent = event
        var toolName: String?
        var toolInput: [String: Any]?
        var toolUseId: String?

        switch event {
        case "BeforeAgent":
            wireEvent = "UserPromptSubmit"
        case "BeforeTool":
            wireEvent = "PreToolUse"
            let normalizedToolName = canonicalGeminiToolName(toolNameValue(payload))
            toolName = normalizedToolName
            toolInput = normalizeGeminiToolInput(toolName: normalizedToolName, rawInput: payload["tool_input"])
                ?? normalizeGeminiToolInput(toolName: normalizedToolName, rawInput: payload["args"])
            toolUseId = normalizedToolUseId(payload: payload, toolInput: toolInput)
        case "BeforeToolSelection":
            wireEvent = "BeforeToolSelection"
        case "BeforeModel":
            wireEvent = "BeforeModel"
        case "AfterTool":
            wireEvent = "PostToolUse"
            let normalizedToolName = canonicalGeminiToolName(toolNameValue(payload))
            toolName = normalizedToolName
            toolInput = normalizeGeminiToolInput(toolName: normalizedToolName, rawInput: payload["tool_input"])
                ?? normalizeGeminiToolInput(toolName: normalizedToolName, rawInput: payload["args"])
            toolUseId = normalizedToolUseId(payload: payload, toolInput: toolInput)
        case "AfterModel":
            wireEvent = "AfterModel"
        case "AfterAgent":
            wireEvent = "Stop"
        case "ToolPermission":
            wireEvent = "ToolPermission"
            let normalizedToolName = canonicalGeminiToolName(toolNameValue(payload))
            toolName = normalizedToolName
            toolInput = normalizeGeminiToolInput(toolName: normalizedToolName, rawInput: payload["tool_input"])
                ?? normalizeGeminiToolInput(toolName: normalizedToolName, rawInput: payload["args"])
            toolUseId = normalizedToolUseId(payload: payload, toolInput: toolInput)
        case "Notification" where isGeminiToolPermissionNotification(payload: payload, notificationType: notificationType):
            wireEvent = "ToolPermission"
            let details = geminiNotificationToolDetails(details: payload["details"])
            toolName = details.name
            toolInput = details.input
            toolUseId = normalizedToolUseId(payload: payload, toolInput: toolInput)
        case "PreCompress":
            wireEvent = "PreCompress"
        default:
            break
        }

        let status: String
        switch wireEvent {
        case "ToolPermission":
            status = "waiting_for_approval"
        case "PreToolUse":
            status = "running_tool"
        case "BeforeToolSelection", "BeforeModel", "AfterModel", "PreCompress":
            status = "processing"
        case "Stop", "SessionStart":
            status = "waiting_for_input"
        case "SessionEnd":
            status = "ended"
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
        // Gemini hooks often use 'sessionId' camelCase
        if message["session_id"] == nil {
            set(&message, "session_id", stringValue(payload["sessionId"]))
        }
        set(&message, "tool_name", toolName)
        set(&message, "tool_input", toolInput)
        set(&message, "tool_use_id", toolUseId ?? normalizedToolUseId(payload: payload, toolInput: toolInput))
        let semanticText = geminiMessage(payload: payload, event: event)
        // Route by wireEvent (the event name downstream consumers see) into
        // the matching semantic lane.
        switch wireEvent {
        case "UserPromptSubmit":
            set(&message, "prompt_text", semanticText)
        case "Notification", "PermissionRequest", "ToolPermission", "SessionStart", "SessionEnd":
            set(&message, "message", semanticText)
        default:
            set(&message, "commentary_text", semanticText)
        }

        if event == "AfterTool", let response = toolResponseText(payload: payload) {
            set(&message, "tool_response", String(response.prefix(HookDefaults.maxToolResponseLength)))
        }

        return HookAction(message: message)
    }
}

private func geminiMessage(payload: [String: Any], event: String) -> String? {
    switch event {
    case "BeforeAgent":
        return firstText(payload["prompt"])
    case "BeforeModel":
        return firstText(payload["llm_request"])
    case "AfterModel":
        return firstText(payload["llm_response"])
    case "AfterAgent":
        return firstText(payload["prompt_response"])
            ?? firstText(payload["prompt"])
            ?? firstText(payload["reason"])
    case "SessionStart":
        return firstText(payload["source"])
    case "SessionEnd":
        return firstText(payload["reason"])
    case "Notification":
        return firstText(payload["message"])
    default:
        return firstText(payload["message"])
            ?? firstText(payload["reason"])
            ?? firstText(payload["warning"])
    }
}

private let geminiToolNameMap: [String: String] = [
    "run_shell_command": "bash",
    "read_file": "read",
    "write_file": "write",
    "replace": "edit",
    "glob": "glob",
    "grep": "grep",
    "grep_search": "grep",
    "web_fetch": "fetch",
    "web_search": "websearch",
    "google_web_search": "websearch",
    "save_memory": "memory",
    "shell": "bash",
    "readfile": "read",
    "searchtext": "grep",
    "findfiles": "glob",
]

private func canonicalGeminiToolName(_ name: String?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return geminiToolNameMap[trimmed] ?? geminiToolNameMap[trimmed.lowercased()] ?? trimmed
}

private func normalizeGeminiToolInput(toolName: String?, rawInput: Any?) -> [String: Any]? {
    guard var input = nestedDictionaryValue(
        rawInput,
        preferredKeys: ["tool_input", "args", "arguments", "parameters", "input"]
    ) else {
        if toolName == "bash", let command = stringValue(rawInput) {
            return ["command": command]
        }
        return nil
    }

    switch toolName {
    case "edit":
        migrateKey(in: &input, from: "filePath", to: "file_path")
        migrateKey(in: &input, from: "absolute_path", to: "file_path")
        migrateKey(in: &input, from: "oldString", to: "old_string")
        migrateKey(in: &input, from: "newString", to: "new_string")
    case "read", "write":
        migrateKey(in: &input, from: "filePath", to: "file_path")
        migrateKey(in: &input, from: "absolute_path", to: "file_path")
    case "bash":
        migrateKey(in: &input, from: "cmd", to: "command")
    default:
        break
    }

    return input
}

private func isGeminiToolPermissionNotification(payload: [String: Any], notificationType: String?) -> Bool {
    let normalizedType = notificationType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["toolpermission", "tool_permission", "permission"].contains(normalizedType ?? "") {
        return true
    }

    guard let details = dictionaryValue(payload["details"]) else { return false }
    let detailType = stringValue(details["type"])?.lowercased()
    return ["exec", "edit", "mcp"].contains(detailType ?? "")
}

private func geminiNotificationToolDetails(details: Any?) -> (name: String?, input: [String: Any]?) {
    guard let details = dictionaryValue(details) else { return (nil, nil) }

    let title = stringValue(details["title"])
    switch stringValue(details["type"]) {
    case "exec":
        return ("bash", compactDictionary([
            "command": stringValue(details["command"]),
            "description": title,
            "root_command": stringValue(details["rootCommand"]),
        ]))
    case "edit":
        return ("edit", compactDictionary([
            "file_path": stringValue(details["filePath"]),
            "description": title,
        ]))
    case "mcp":
        return (stringValue(details["toolName"]) ?? "mcp", compactDictionary([
            "server_name": stringValue(details["serverName"]),
            "tool_display_name": stringValue(details["toolDisplayName"]),
            "description": title,
        ]))
    case "info":
        return ("info", compactDictionary([
            "prompt": stringValue(details["prompt"]),
            "description": title,
        ]))
    default:
        return (title, compactDictionary([
            "description": title,
        ]))
    }
}

private func migrateKey(in object: inout [String: Any], from source: String, to destination: String) {
    guard object[destination] == nil, let value = object[source] else { return }
    object[destination] = value
}

private func compactDictionary(_ object: [String: Any?]) -> [String: Any]? {
    var result: [String: Any] = [:]
    for (key, value) in object {
        if let value {
            result[key] = value
        }
    }
    return result.isEmpty ? nil : result
}
