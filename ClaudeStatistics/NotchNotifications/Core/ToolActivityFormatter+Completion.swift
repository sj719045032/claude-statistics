import Foundation

// "Completion" family: produce a `ToolOutputSummary` from a finished tool
// invocation (PostToolUse / PostToolUseFailure / SubagentStop). Prefers
// semantic summaries ("Read Foo.swift", "Searched: bar") over raw stdout
// snippets so the notch row reads like a status panel rather than a tail
// of terminal output.
extension ToolActivityFormatter {
    static func toolOutputSummary(
        rawEventName: String,
        toolName: String?,
        input: [String: JSONValue]?,
        response: String?,
        toolUseId: String?
    ) -> ToolOutputSummary? {
        if rawEventName == "SubagentStop" {
            if let summary = summarizeToolCompletion(toolName: toolName, input: input ?? [:], response: response, toolUseId: toolUseId) {
                return summary
            }
            guard let response,
                  let snippet = ToolOutputCleaning.snippet(from: response),
                  !ToolOutputCleaning.isPlaceholderOutput(snippet) else { return nil }
            return ToolOutputSummary(text: snippet, kind: .rawSnippet)
        }

        guard rawEventName == "PostToolUse" || rawEventName == "PostToolUseFailure" else {
            return nil
        }

        return summarizeToolCompletion(toolName: toolName, input: input ?? [:], response: response, toolUseId: toolUseId)
    }

    fileprivate static func summarizeToolCompletion(
        toolName: String?,
        input: [String: JSONValue],
        response: String?,
        toolUseId: String?
    ) -> ToolOutputSummary? {
        let tool = canonicalToolName(toolName)
        let key = semanticKey(forTool: toolName, input: input, toolUseId: toolUseId)

        switch tool {
        case "read", "glob", "websearch", "web_search", "webfetch", "fetch", "todowrite",
             "enterplanmode", "exitplanmode":
            if let summary = completedOperationSummary(tool: tool, input: input) {
                return ToolOutputSummary(text: summary, kind: .echo, semanticKey: key)
            }
        case "write", "edit", "multiedit", "task", "agent":
            if let summary = completedOperationSummary(tool: tool, input: input) {
                return ToolOutputSummary(text: summary, kind: .result, semanticKey: key)
            }
        case "grep":
            if let response, let result = grepResultSummary(response: response, input: input) {
                return ToolOutputSummary(text: result, kind: .result, semanticKey: key)
            }
            if let summary = completedOperationSummary(tool: tool, input: input) {
                return ToolOutputSummary(text: summary, kind: .echo, semanticKey: key)
            }
        case "bash", "bashoutput":
            if let command = preferredText(in: input, keys: ["command"]),
               let summary = shellCommandSummary(command) {
                if let response, let result = shellResultSummary(response) {
                    return ToolOutputSummary(text: result, kind: .result, semanticKey: key)
                }
                return ToolOutputSummary(text: truncate(summary.operation, limit: 160), kind: .echo, semanticKey: key)
            }
            if let description = preferredText(in: input, keys: ["description"]), !description.isEmpty {
                if let response, let result = shellResultSummary(response) {
                    return ToolOutputSummary(text: result, kind: .result, semanticKey: key)
                }
                return ToolOutputSummary(text: truncate(description, limit: 160), kind: .echo, semanticKey: key)
            }
        default:
            break
        }

        guard let response,
              let snippet = ToolOutputCleaning.snippet(from: response),
              !ToolOutputCleaning.isPlaceholderOutput(snippet) else { return nil }
        return ToolOutputSummary(text: snippet, kind: .rawSnippet)
    }

    fileprivate static func completedOperationSummary(tool: String, input: [String: JSONValue]) -> String? {
        let summary = runningSummary(tool: tool, input: input)
        let trimmed = summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func grepResultSummary(response: String, input: [String: JSONValue]) -> String? {
        let lines = usefulResponseLines(response)
        guard !lines.isEmpty else { return nil }
        if lines.count == 1, let line = lines.first, !line.contains(":") {
            return truncate(line, limit: 160)
        }
        if let pattern = preferredText(in: input, keys: ["pattern"]) {
            return truncate(localizedFormat("notch.operation.foundMatchesNamed", pattern, lines.count), limit: 160)
        }
        return truncate(localizedFormat("notch.operation.foundMatches", lines.count), limit: 160)
    }

    fileprivate static func shellResultSummary(_ response: String) -> String? {
        let lines = usefulResponseLines(response)
        guard let line = lines.last else { return nil }
        let lower = line.lowercased()
        if lower.contains("build succeeded") || lower.contains("tests passed") || lower.contains("test passed") {
            return truncate(line, limit: 160)
        }
        if lower.contains("build failed") || lower.contains("error:") || lower.contains("failed") {
            return truncate(line, limit: 160)
        }
        return nil
    }

    fileprivate static func usefulResponseLines(_ response: String) -> [String] {
        response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ToolOutputCleaning.cleanedLine(ToolOutputCleaning.stripAnsi(String($0))) }
            .filter {
                !$0.isEmpty
                    && !ToolOutputCleaning.isUnhelpfulMetadataLine($0)
                    && !ToolOutputCleaning.isPlaceholderOutput($0)
            }
    }
}
