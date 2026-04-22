import Foundation

enum ToolActivityFormatter {
    static func operationSummary(tool: String, input: [String: JSONValue]) -> String? {
        for key in operationPreferredKeys(for: tool) {
            if let value = input[key], let rendered = render(value), !rendered.isEmpty {
                return truncate(rendered, limit: 180)
            }
        }

        return detailSummary(tool: tool, input: input)
    }

    static func permissionDetails(tool: String, input: [String: JSONValue]) -> [String] {
        switch tool.lowercased() {
        case "bash":
            var lines: [String] = []
            if let command = preferredText(in: input, keys: ["command"]) {
                lines.append(command)
            }
            if let description = preferredText(in: input, keys: ["description"]),
               !description.isEmpty,
               description != lines.first {
                lines.append(description)
            }
            if let warning = preferredText(in: input, keys: ["warning", "reason", "message"]),
               !warning.isEmpty,
               !lines.contains(warning) {
                lines.append(warning)
            }
            if !lines.isEmpty {
                return lines.map { truncate($0, limit: 280) }
            }

        case "read", "write", "edit", "multiedit":
            var lines: [String] = []
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                lines.append(path)
            }
            if let instruction = preferredText(in: input, keys: ["description", "prompt"]),
               !instruction.isEmpty,
               !lines.contains(instruction) {
                lines.append(instruction)
            }
            if !lines.isEmpty {
                return lines.map { truncate($0, limit: 280) }
            }

        case "websearch", "web_search":
            var lines: [String] = []
            if let query = preferredText(in: input, keys: ["query", "prompt", "q"]) {
                lines.append(query)
            }
            if let note = preferredText(in: input, keys: ["description", "reason"]),
               !note.isEmpty,
               !lines.contains(note) {
                lines.append(note)
            }
            if !lines.isEmpty {
                return lines.map { truncate($0, limit: 280) }
            }

        default:
            break
        }

        let fallback = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key], let rendered = render(value), !rendered.isEmpty else { return nil }
            return truncate("\(prettyKey(key)): \(rendered)", limit: 280)
        }
        return Array(fallback.prefix(3))
    }

    static func detailSummary(tool: String, input: [String: JSONValue]) -> String? {
        for key in preferredKeys(for: tool) {
            if let value = input[key], let rendered = render(value), !rendered.isEmpty {
                return truncate(rendered, limit: 220)
            }
        }

        let pairs = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key], let rendered = render(value), !rendered.isEmpty else { return nil }
            return "\(prettyKey(key)): \(rendered)"
        }

        guard !pairs.isEmpty else { return nil }
        return truncate(pairs.joined(separator: "  "), limit: 220)
    }

    static func liveSummary(
        rawEventName: String,
        notificationType: String?,
        toolName: String?,
        input: [String: JSONValue]?,
        provider: ProviderKind
    ) -> String? {
        switch rawEventName {
        case "PermissionRequest":
            // The notch card itself shows "Approve {tool}: …" prominently.
            // Don't overwrite the more useful running activity ("Rebuild with
            // go 1.26") that PreToolUse just set — Claude Code fires events
            // in the order PreToolUse → PermissionRequest → PostToolUse, and
            // PostToolUse returns nil too, so without this we'd be stuck on
            // "Approve Bash" long after the tool started running.
            return nil

        case "ToolPermission":
            guard let toolName else { return fallbackProcessingText(for: provider) }
            return runningSummary(tool: toolName, input: input ?? [:])

        case "PreToolUse":
            guard let toolName else { return fallbackProcessingText(for: provider) }
            return runningSummary(tool: toolName, input: input ?? [:])

        case "UserPromptSubmit":
            // A new user turn starts — reset activity to the generic fallback.
            return fallbackProcessingText(for: provider)

        case "SubagentStart":
            if let toolName {
                return "Running \(toolName)…"
            }
            return fallbackProcessingText(for: provider)

        case "BeforeToolSelection":
            return "Choosing tools…"

        case "BeforeModel":
            return fallbackProcessingText(for: provider)

        case "PreCompress":
            return "Compressing context…"

        case "PreCompact":
            return "Compacting context…"

        case "PostToolUse", "PostToolUseFailure", "SubagentStop", "PostCompact", "AfterModel":
            // Don't overwrite the richer PreToolUse/SubagentStart activity
            // with a generic "Thinking…" — let the previous line persist until
            // the next tool starts, so the UI reads "Reading foo.swift…" rather
            // than flipping to the vague fallback between tool calls.
            return nil

        case "Notification":
            // permission_prompt is fired alongside PermissionRequest, which
            // already sets a more specific "Approve {tool}: …" activity. The
            // generic "Waiting for approval…" string just stomps on that, so
            // drop it and let PermissionRequest drive the runtime activity.
            return nil

        case "SessionStart":
            return "Starting…"

        default:
            return nil
        }
    }

    private static func runningSummary(tool: String, input: [String: JSONValue]) -> String {
        switch tool.lowercased() {
        case "read":
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                return "Reading \(lastPathComponent(path))…"
            }
            return "Reading…"

        case "edit", "multiedit":
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                return "Editing \(lastPathComponent(path))…"
            }
            return "Editing…"

        case "write":
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                return "Writing \(lastPathComponent(path))…"
            }
            return "Writing…"

        case "bash":
            if let description = preferredText(in: input, keys: ["description"]), !description.isEmpty {
                return truncate(description, limit: 140)
            }
            if let command = preferredText(in: input, keys: ["command"]) {
                return truncate("Running: \(command)", limit: 140)
            }
            return "Running command…"

        case "grep", "glob":
            if let pattern = preferredText(in: input, keys: ["pattern"]) {
                return truncate("Searching: \(pattern)", limit: 140)
            }
            return "Searching…"

        case "websearch", "web_search":
            if let query = preferredText(in: input, keys: ["query", "prompt", "q"]) {
                return truncate("Searching: \(query)", limit: 140)
            }
            return "Searching the web…"

        case "webfetch", "fetch":
            if let url = preferredText(in: input, keys: ["url"]) {
                return truncate("Fetching: \(url)", limit: 140)
            }
            return "Fetching…"

        case "task", "agent":
            if let description = preferredText(in: input, keys: ["description", "prompt"]) {
                return truncate(description, limit: 140)
            }
            return "Running agent…"

        case "todowrite":
            return "Updating todos…"

        case "enterplanmode":
            return "Entering plan mode…"

        case "exitplanmode":
            return "Exiting plan mode…"

        default:
            if let detail = detailSummary(tool: tool, input: input) {
                return truncate("\(tool): \(detail)", limit: 140)
            }
            return "\(tool)…"
        }
    }

    private static func fallbackProcessingText(for provider: ProviderKind) -> String {
        switch provider {
        case .claude:
            return "Thinking…"
        case .codex, .gemini:
            return "Working…"
        }
    }

    private static func preferredKeys(for tool: String) -> [String] {
        switch tool.lowercased() {
        case "websearch", "web_search":
            return ["query", "prompt", "q", "url"]
        case "bash":
            return ["description", "command"]
        case "read", "write", "edit", "multiedit":
            return ["file_path", "path"]
        case "grep", "glob":
            return ["pattern", "path"]
        case "task", "agent":
            return ["description", "prompt"]
        default:
            return ["command", "query", "prompt", "message", "url", "file_path", "path", "pattern", "description"]
        }
    }

    private static func operationPreferredKeys(for tool: String) -> [String] {
        switch tool.lowercased() {
        case "bash":
            return ["command", "description"]
        case "read", "write", "edit", "multiedit":
            return ["file_path", "path", "description", "prompt"]
        case "grep", "glob":
            return ["pattern", "path"]
        case "websearch", "web_search":
            return ["query", "prompt", "q"]
        case "webfetch", "fetch":
            return ["url"]
        case "task", "agent":
            return ["description", "prompt"]
        default:
            return ["command", "query", "prompt", "url", "file_path", "path", "pattern", "description"]
        }
    }

    private static func preferredText(in input: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = input[key], let rendered = render(value), !rendered.isEmpty {
                return rendered
            }
        }
        return nil
    }

    private static func lastPathComponent(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? path : last
    }

    private static func prettyKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    private static func render(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            let trimmed = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let number):
            let integer = Int(number)
            if Double(integer) == number { return "\(integer)" }
            return "\(number)"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return nil
        case .array(let items):
            let parts = items.compactMap(render)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object(let object):
            let pairs = object.keys.sorted().compactMap { key -> String? in
                guard let rendered = object[key].flatMap(render) else { return nil }
                return "\(prettyKey(key)): \(rendered)"
            }
            return pairs.isEmpty ? nil : pairs.joined(separator: ", ")
        }
    }
}
