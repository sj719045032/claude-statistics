import Foundation

/// Shared utilities for provider transcript parsers (Claude / Codex / Gemini).
///
/// Per CLAUDE.md *Provider Code Organization*: parsing/sanitizing/formatting
/// behaviour that's common across providers lives here; provider-specific
/// quirks stay in each provider's own parser via the `envelopeCheck` hook on
/// `searchTextClean(_:envelopeCheck:)`.
public enum TranscriptParserCommons {

    /// Truncate `text` to `limit` characters, appending an ellipsis when cut.
    public static func truncate(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Round `date` down to the start of its 5-minute slice. Used as the
    /// bucketing key for fiveMinSlices in `SessionStats`.
    ///
    /// Note: Claude's parser uses an additional rule that attributes the
    /// midnight hour to the previous day — see `TranscriptParser.fiveMinKey`.
    public static func fiveMinuteSliceKey(for date: Date) -> Date {
        var comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        comps.minute = ((comps.minute ?? 0) / 5) * 5
        return Calendar.current.date(from: comps) ?? date
    }

    /// Parse an ISO-8601 timestamp string, accepting both fractional-seconds
    /// and plain forms.
    public static func parseISOTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return ISO.full.date(from: raw) ?? ISO.fallback.date(from: raw)
    }

    private enum ISO {
        static let full: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        static let fallback: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()
    }

    /// Clean a transcript snippet for FTS indexing: trim, drop instruction
    /// envelopes (provider-specific filter), strip markdown, length filter.
    /// Returns nil if the result is empty or too short.
    public static func searchTextClean(
        _ text: String,
        envelopeCheck: (String) -> Bool = { _ in false }
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return nil }
        if envelopeCheck(trimmed) { return nil }
        let stripped = stripMarkdown(trimmed)
        return stripped.count > 2 ? stripped : nil
    }

    /// Strip markdown syntax for search matching.
    /// Removes code fences, links, bold/italic, inline code, headings.
    public static func stripMarkdown(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```\\w*\\n?", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*{1,2}([^*]+)\\*{1,2}", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_{1,2}([^_]+)_{1,2}", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^>\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return s
    }
}
