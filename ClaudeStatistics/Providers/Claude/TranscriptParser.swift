import Foundation
import ClaudeStatisticsKit

final class TranscriptParser {
    static let shared = TranscriptParser()

    private init() {}

    /// Max length of an assistant preview text. Kept generous so the notch
    /// expanded waiting card can show full multi-paragraph markdown without
    /// losing the tail. Session-list rows UI-side already limits lines.
    static let assistantPreviewLimit = 4000

    // MARK: - Shared helpers (used by multiple parsers)

    /// Extract text from a tool_result content field
    static func extractToolResultText(_ content: AnyCodable?) -> String? {
        guard let content else { return nil }

        // String result (Read, Bash, Grep, Glob)
        if let str = content.stringValue, !str.isEmpty {
            return str
        }

        // Array result (Agent)
        if let arr = content.value as? [[String: Any]] {
            let texts = arr.compactMap { item -> String? in
                guard (item["type"] as? String) == "text" else { return nil }
                return item["text"] as? String
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }

        return nil
    }

    static func clampAssistantPreview(_ s: String) -> String {
        s.count > assistantPreviewLimit ? String(s.prefix(assistantPreviewLimit)) + "…" : s
    }

    static func extractAssistantPreview(from message: TranscriptMessage) -> String? {
        if let contentString = message.contentString {
            let trimmed = contentString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return clampAssistantPreview(trimmed)
            }
        }

        // Only surface the assistant's natural-language text. Bare tool_use /
        // thinking / tool_result entries aren't meaningful as a row preview —
        // caller walks back further to find the last real text reply.
        guard let items = message.content else { return nil }
        for item in items.reversed() {
            if case .text(let text) = item {
                let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("[Request interrupted by user") else { continue }
                return clampAssistantPreview(trimmed)
            }
        }
        return nil
    }

    static func extractAssistantPreview(fromRawMessage message: [String: Any]) -> String? {
        if let contentString = message["content"] as? String {
            let trimmed = contentString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return clampAssistantPreview(trimmed)
            }
        }

        guard let items = message["content"] as? [[String: Any]] else { return nil }
        for item in items.reversed() {
            guard item["type"] as? String == "text" else { continue }
            let trimmed = (item["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("[Request interrupted by user") else { continue }
            return clampAssistantPreview(trimmed)
        }
        return nil
    }

    static func cleanSearchText(_ text: String) -> String? {
        TranscriptParserCommons.searchTextClean(text) { trimmed in
            isInternalUserMessage(trimmed)
                || (trimmed.hasPrefix("[Image: source:") && trimmed.hasSuffix("]"))
        }
    }

    /// Extract all text content from a message entry (user or assistant)
    static func extractAllText(from entry: TranscriptEntry) -> String? {
        guard let message = entry.message else { return nil }

        if let str = message.contentString {
            return str
        }

        if let content = message.content {
            let texts = content.compactMap { item -> String? in
                if case .text(let tc) = item { return tc.text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }

        return nil
    }

    /// Clean up user text into a short topic line
    static func cleanTopic(_ text: String) -> String? {
        guard let trimmed = cleanUserDisplayText(text) else { return nil }
        return TitleSanitizer.sanitize(trimmed)
    }

    static func cleanUserDisplayText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isInternalUserMessage(trimmed) else { return nil }
        return trimmed
    }

    static func isInternalUserMessage(_ text: String) -> Bool {
        guard text.hasPrefix("<") else { return false }

        // Bare standalone tag (e.g. <local-command-stdout>)
        if text.range(
            of: #"^<{1,2}/?[A-Za-z][A-Za-z0-9_-]*(\s+[^>]*)?>{1,2}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // Tag with content (e.g. <local-command-stdout>Set model…</local-command-stdout>)
        if text.range(of: #"^<[a-z][a-z0-9-]*>"#, options: .regularExpression) != nil {
            return true
        }

        return text.contains("<ide_opened_file>")
            || text.contains("<command-message>")
            || text.contains("<local-command-caveat>")
            || text.contains("<system-reminder>")
            || text.contains("<task-notification>")
            || text.contains("<task-id>")
            || text.contains("<tool-use-id>")
    }
}
