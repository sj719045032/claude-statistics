import Foundation

/// Shared helpers for turning raw tool stdout into the short, UI-friendly
/// text the notch row and transcript view show. Centralised so the Notch
/// runtime, the transcript parser, and any other consumer all agree on
/// which lines are "noise" (ANSI escapes, "Process group pgid:" footers,
/// placeholder words like "json"/"stdout") and how a snippet is selected
/// (last useful line, capped at 100 chars).
public enum ToolOutputCleaning {
    /// Trim whitespace; strip a leading "Output:" prefix that some CLIs
    /// prepend to every line. Returns the empty string when the input is
    /// pure whitespace so callers can `.filter { !$0.isEmpty }`.
    public static func cleanedLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.lowercased().hasPrefix("output:") {
            return trimmed.dropFirst("Output:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    public static func isUnhelpfulMetadataLine(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("process group pgid:")
            || normalized.hasPrefix("background pids:")
    }

    /// Quick CSI-escape stripper. Avoids pulling in a regex engine for what
    /// is effectively a 3-line state machine: ESC `[`, then params /
    /// intermediate bytes, then a final byte 0x40-0x7E.
    public static func stripAnsi(_ text: String) -> String {
        var result = ""
        var iter = text.unicodeScalars.makeIterator()
        while let c = iter.next() {
            if c == "\u{001B}" {
                if let next = iter.next(), next == "[" {
                    while let cc = iter.next() {
                        if cc.value >= 0x40 && cc.value <= 0x7E { break }
                    }
                }
                continue
            }
            result.unicodeScalars.append(c)
        }
        return result
    }

    /// Single-word "this is not the actual output" markers some tools emit
    /// in lieu of an empty response. Showing these in the notch is worse
    /// than showing nothing.
    public static func isPlaceholderOutput(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "text"
            || normalized == "json"
            || normalized == "stdout"
            || normalized == "output"
            || normalized == "(empty)"
            || normalized == "---"
            || normalized == "--"
    }

    /// Take the LAST non-empty, non-noise line of `raw` (most recent stdout
    /// for streaming commands), strip ANSI/whitespace, cap at 100 chars
    /// with an ellipsis. Returns nil when nothing usable remains.
    public static func snippet(from raw: String) -> String? {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { cleanedLine(stripAnsi(String($0))) }
            .filter { !$0.isEmpty && !isUnhelpfulMetadataLine($0) && !isPlaceholderOutput($0) }
        guard let tail = lines.last else { return nil }
        return tail.count > 100 ? String(tail.prefix(100)) + "…" : tail
    }
}
