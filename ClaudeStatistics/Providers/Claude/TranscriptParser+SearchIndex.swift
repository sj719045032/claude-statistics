import Foundation
import ClaudeStatisticsKit

extension TranscriptParser {
    /// Lightweight transcript extraction for FTS indexing. Keep this separate from
    /// parseMessages so startup indexing does not pay UI transcript costs.
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let content = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()

        var messages: [SearchIndexMessage] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }

            switch entry.type {
            case "queue-operation":
                if entry.operation == "enqueue",
                   let text = entry.content,
                   let content = Self.cleanSearchText(text) {
                    messages.append(SearchIndexMessage(role: "user", content: content, timestamp: entry.timestampDate))
                }

            case "user", "human":
                guard let text = Self.extractAllText(from: entry),
                      let content = Self.cleanSearchText(text) else { continue }
                messages.append(SearchIndexMessage(role: "user", content: content, timestamp: entry.timestampDate))

            case "assistant":
                if let text = Self.extractAllText(from: entry),
                   let content = Self.cleanSearchText(text) {
                    messages.append(SearchIndexMessage(role: "assistant", content: content, timestamp: entry.timestampDate))
                }

                guard let items = entry.message?.content else { continue }
                for item in items {
                    switch item {
                    case .toolUse(let tool):
                        guard let content = Self.searchText(forToolUse: tool) else { continue }
                        messages.append(SearchIndexMessage(role: "tool", content: content, timestamp: entry.timestampDate))
                    case .toolResult(let result):
                        guard let text = Self.extractToolResultText(result.content),
                              let content = Self.cleanSearchText(String(text.prefix(500))) else { continue }
                        messages.append(SearchIndexMessage(role: "tool", content: content, timestamp: entry.timestampDate))
                    default:
                        continue
                    }
                }

            default:
                continue
            }
        }

        return messages
    }

    fileprivate static func searchText(forToolUse tool: TranscriptContent.ToolUseContent) -> String? {
        var parts: [String] = []
        if let name = tool.name { parts.append(name) }

        if let dict = tool.input?.value as? [String: Any] {
            for key in ["file_path", "path", "pattern"] {
                if let value = dict[key] as? String { parts.append(value) }
            }
            if let command = dict["command"] as? String { parts.append(String(command.prefix(500))) }
            if let content = dict["content"] as? String { parts.append(String(content.prefix(2_000))) }
            if let oldString = dict["old_string"] as? String { parts.append(String(oldString.prefix(1_000))) }
            if let newString = dict["new_string"] as? String { parts.append(String(newString.prefix(1_000))) }
        }

        return cleanSearchText(parts.joined(separator: "\n"))
    }
}
