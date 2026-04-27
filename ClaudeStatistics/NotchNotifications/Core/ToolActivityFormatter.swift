import ClaudeStatisticsKit
import Foundation

enum ToolActivityFormatter {
    static func localized(_ key: String) -> String {
        LanguageManager.localizedString(key)
    }

    static func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: LanguageManager.currentLocale, arguments: arguments)
    }

    /// Thin wrapper that forwards to the provider-agnostic resolver in
    /// `CanonicalToolName`. Callers that have a `ProviderKind` in scope
    /// should prefer `provider.canonicalToolName(raw)` directly; this helper
    /// exists for formatter paths (`summarizeToolCompletion`, `semanticKey`,
    /// `preferredKeys`, …) that don't receive a provider but still need a
    /// stable canonical form.
    static func canonicalToolName(_ raw: String?) -> String {
        HostCanonicalToolName.resolve(raw)
    }

    static func currentOperation(
        rawEventName: String,
        toolName: String?,
        input: [String: JSONValue]?,
        provider: ProviderKind,
        receivedAt: Date,
        toolUseId: String?
    ) -> CurrentOperation? {
        switch rawEventName {
        case "PreToolUse":
            let resolvedTool = toolName ?? ""
            let text = toolName.map { runningSummary(tool: $0, input: input ?? [:]) }
                ?? fallbackProcessingText(for: provider)
            return CurrentOperation(
                kind: .tool,
                text: text,
                symbol: ActiveSession.toolSymbol(resolvedTool),
                startedAt: receivedAt,
                toolName: toolName,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forTool: toolName, input: input ?? [:], toolUseId: toolUseId)
            )

        case "SubagentStart":
            let text: String
            if let toolName {
                text = localizedFormat("notch.operation.runningToolNamed", toolName)
            } else {
                text = localized("notch.operation.runningSubagent")
            }
            return CurrentOperation(
                kind: .subagent,
                text: text,
                symbol: "wand.and.stars",
                startedAt: receivedAt,
                toolName: toolName,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forTool: toolName, input: input ?? [:], toolUseId: toolUseId)
            )

        case "BeforeToolSelection":
            return CurrentOperation(
                kind: .toolSelection,
                text: localized("notch.operation.choosingTools"),
                symbol: "slider.horizontal.3",
                startedAt: receivedAt,
                toolName: nil,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forOperation: rawEventName, toolUseId: toolUseId)
            )

        case "BeforeModel":
            return CurrentOperation(
                kind: .modelThinking,
                text: fallbackProcessingText(for: provider),
                symbol: "sparkles",
                startedAt: receivedAt,
                toolName: nil,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forOperation: rawEventName, toolUseId: toolUseId)
            )

        case "PreCompress":
            return CurrentOperation(
                kind: .compressing,
                text: localized("notch.operation.compressingContext"),
                symbol: "arrow.down.left.and.arrow.up.right",
                startedAt: receivedAt,
                toolName: nil,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forOperation: rawEventName, toolUseId: toolUseId)
            )

        case "PreCompact":
            return CurrentOperation(
                kind: .compacting,
                text: localized("notch.operation.compactingContext"),
                symbol: "arrow.down.left.and.arrow.up.right",
                startedAt: receivedAt,
                toolName: nil,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forOperation: rawEventName, toolUseId: toolUseId)
            )

        case "UserPromptSubmit":
            return CurrentOperation(
                kind: .genericProcessing,
                text: fallbackProcessingText(for: provider),
                symbol: "sparkles",
                startedAt: receivedAt,
                toolName: nil,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forOperation: rawEventName, toolUseId: toolUseId)
            )

        case "SessionStart":
            return CurrentOperation(
                kind: .genericProcessing,
                text: localized("notch.operation.starting"),
                symbol: "play.circle",
                startedAt: receivedAt,
                toolName: nil,
                toolUseId: toolUseId,
                semanticKey: semanticKey(forOperation: rawEventName, toolUseId: toolUseId)
            )

        default:
            return nil
        }
    }

    static func detailSummary(tool: String, input: [String: JSONValue]) -> String? {
        for key in preferredKeys(for: tool) {
            if let value = input[key], let rendered = renderForKey(key, value), !rendered.isEmpty {
                return truncate(rendered, limit: 220)
            }
        }

        let pairs = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key], let rendered = renderForKey(key, value), !rendered.isEmpty else { return nil }
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
                return localizedFormat("notch.operation.runningToolNamed", toolName)
            }
            return fallbackProcessingText(for: provider)

        case "BeforeToolSelection":
            return localized("notch.operation.choosingTools")

        case "BeforeModel":
            return fallbackProcessingText(for: provider)

        case "PreCompress":
            return localized("notch.operation.compressingContext")

        case "PreCompact":
            return localized("notch.operation.compactingContext")

        case "PostToolUse", "PostToolUseFailure", "SubagentStop", "PostCompact", "AfterModel":
            // Transition back to a generic "Thinking..." or "Working..." state
            // so the Notch stays active and clearly indicates progress between
            // tool calls or while finishing a turn.
            return fallbackProcessingText(for: provider)

        case "Notification":
            // permission_prompt is fired alongside PermissionRequest, which
            // already sets a more specific "Approve {tool}: …" activity. The
            // generic "Waiting for approval…" string just stomps on that, so
            // drop it and let PermissionRequest drive the runtime activity.
            return nil

        case "SessionStart":
            return localized("notch.operation.starting")

        default:
            return nil
        }
    }

    static func liveSemanticKey(
        rawEventName: String,
        toolName: String?,
        input: [String: JSONValue]?,
        toolUseId: String?
    ) -> String? {
        switch rawEventName {
        case "ToolPermission", "PreToolUse", "SubagentStart":
            return semanticKey(forTool: toolName, input: input ?? [:], toolUseId: toolUseId)
        case "UserPromptSubmit", "BeforeToolSelection", "BeforeModel", "PreCompress", "PreCompact", "SessionStart":
            return semanticKey(forOperation: rawEventName, toolUseId: toolUseId)
        default:
            return nil
        }
    }

    private static func fallbackProcessingText(for provider: ProviderKind) -> String {
        localized(provider.descriptor.notchProcessingHintKey)
    }

    private static func preferredKeys(for tool: String) -> [String] {
        switch canonicalToolName(tool) {
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

    static func preferredText(in input: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = input[key], let rendered = renderForKey(key, value), !rendered.isEmpty {
                return rendered
            }
        }
        return nil
    }

    /// Path-like keys whose string values should be stripped of paren/bracket
    /// wrappers and surrounding quotes before display. Claude hooks sometimes
    /// forward `file_path` still wrapped like `(\t"UsageView.swift" )`, so we
    /// apply the same cleanup `fileOperationSummary` uses for primary paths.
    private static let pathLikeRenderKeys: Set<String> = [
        "file_path", "filepath", "path",
        "file_paths", "filepaths", "paths"
    ]

    static func renderForKey(_ key: String, _ value: JSONValue) -> String? {
        if case .string(let text) = value, pathLikeRenderKeys.contains(key.lowercased()) {
            let cleaned = normalizedPathText(text)
            return cleaned.isEmpty ? nil : cleaned
        }
        return render(value)
    }


    /// Basename plus as many leading parent segments as fit under `maxLength`.
    /// Short repo-relative paths show in full; deep absolute paths degrade to
    /// their trailing 2–3 segments so the row never runs past its budget.
    static func displayPath(_ raw: String, maxLength: Int = 60) -> String {
        let normalized = normalizedPathText(raw)
        let expanded = (normalized as NSString).expandingTildeInPath
        let components = (expanded as NSString).pathComponents.filter { $0 != "/" }
        guard let last = components.last, !last.isEmpty else { return normalized }

        var chosen = last
        var index = components.count - 2
        while index >= 0 {
            let candidate = components[index...].joined(separator: "/")
            if candidate.count > maxLength { break }
            chosen = candidate
            index -= 1
        }
        return chosen
    }

    static func preferredPaths(in input: [String: JSONValue], keys: [String]) -> [String] {
        for key in keys {
            guard let value = input[key] else { continue }
            let paths = extractPaths(from: value)
            if !paths.isEmpty {
                return paths
            }
        }
        return []
    }

    private static func extractPaths(from value: JSONValue) -> [String] {
        switch value {
        case .string(let text):
            let trimmed = normalizedPathText(text)
            return trimmed.isEmpty ? [] : [trimmed]
        case .array(let items):
            return items.flatMap(extractPaths(from:))
        case .object(let object):
            for key in ["file_path", "path", "file_paths", "paths"] {
                if let nested = object[key] {
                    let extracted = extractPaths(from: nested)
                    if !extracted.isEmpty {
                        return extracted
                    }
                }
            }
            return []
        case .number, .bool, .null:
            return []
        }
    }

    static func lastPathComponent(_ path: String) -> String {
        let normalized = normalizedPathText(path)
        let expanded = (normalized as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? normalized : last
    }

    static func semanticKey(forOperation operation: String, toolUseId: String?) -> String {
        if let id = nonEmptySemanticValue(toolUseId) {
            return "operation:\(operation.lowercased()):\(id)"
        }
        return "operation:\(operation.lowercased())"
    }

    static func semanticKey(
        forTool toolName: String?,
        input: [String: JSONValue],
        toolUseId: String?
    ) -> String? {
        if let id = nonEmptySemanticValue(toolUseId) {
            return "tool-use:\(id)"
        }

        let tool = canonicalToolName(toolName)
        guard !tool.isEmpty else { return nil }

        if let command = preferredText(in: input, keys: ["command"]) {
            return "tool:\(tool):command:\(semanticText(command))"
        }

        let paths = preferredPaths(in: input, keys: ["file_path", "path", "file_paths", "paths"])
        if !paths.isEmpty {
            let joined = paths
                .map { semanticText(normalizedPathText($0)) }
                .joined(separator: "|")
            return "tool:\(tool):paths:\(joined)"
        }

        if let pattern = preferredText(in: input, keys: ["pattern"]) {
            return "tool:\(tool):pattern:\(semanticText(pattern))"
        }

        return "tool:\(tool)"
    }

    private static func nonEmptySemanticValue(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func semanticText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func normalizedPathText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some tool payloads stringify path lists as `("foo.swift")` or
        // `["foo.swift"]`. Strip the wrapping punctuation before we compute
        // the display name so the UI reads `Reading foo.swift...`.
        let wrapperPairs: [(Character, Character)] = [
            ("(", ")"),
            ("[", "]"),
            ("{", "}")
        ]

        var didTrimWrapper = true
        while didTrimWrapper, text.count >= 2 {
            didTrimWrapper = false
            for (start, end) in wrapperPairs {
                guard text.first == start, text.last == end else { continue }
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                didTrimWrapper = true
                break
            }
        }

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prettyKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    static func truncate(_ text: String, limit: Int, preserveNewlines: Bool = false) -> String {
        let normalized: String
        if preserveNewlines {
            // Keep line breaks (heredocs, multi-line scripts) but normalize
            // CRLF → LF and strip trailing/leading whitespace.
            normalized = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            normalized = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
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
