import Foundation

/// Cleans up the "first user message" before it ends up as a session
/// title. Strips internal tag wrappers, image-upload markers, ANSI
/// escape leftovers, and hook echoes. Returns `nil` when nothing
/// useful remains, so callers can fall through to the next candidate
/// (e.g. topic → sessionName → "Untitled").
///
/// This lives in the SDK because it's pure shared behaviour — every
/// provider's transcript parser pipes its raw user-text candidate
/// through it before populating `SessionQuickStats`.
public enum TitleSanitizer {
    /// Internal tag names whose wrapped content is rendered output, not
    /// user prose. We try to unwrap them once; the inside is then run
    /// through the rest of the pipeline (ANSI strip etc.) and may still
    /// be rejected if it ends up empty.
    private static let internalTagNames: Set<String> = [
        "ide_opened_file",
        "command-message",
        "command-name",
        "command-args",
        "local-command-stdout",
        "local-command-stderr",
        "local-command-caveat",
        "system-reminder",
        "task-notification",
        "task-id",
        "tool-use-id",
        "user-prompt-submit-hook"
    ]

    private static let ansiEscape = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;]*[A-Za-z]",
        options: []
    )

    /// Bare CSI sequences whose ESC byte was already stripped during
    /// logging — e.g. `[1mSonnet[22m`. Conservative: only `[digits;…m`,
    /// so it doesn't eat user text like `[FIXME]` or `[draft]`.
    private static let bareAnsi = try! NSRegularExpression(
        pattern: #"\[[0-9;]+m"#,
        options: []
    )

    private static let imagePrefix = try! NSRegularExpression(
        pattern: #"^(?:\[Image #\d+\]\s*)+"#,
        options: []
    )

    /// "● Ran 1 stop hook (ctrl+o to expand)" — Claude Code's hook echo.
    private static let hookEcho = try! NSRegularExpression(
        pattern: #"^[●•]?\s*Ran\s+\d+\s+\S+\s+hook\b.*$"#,
        options: [.caseInsensitive]
    )

    private static let lonelyTag = try! NSRegularExpression(
        pattern: #"^<{1,2}/?[A-Za-z][A-Za-z0-9_-]*(\s+[^>]*)?>{1,2}$"#,
        options: []
    )

    private static let wrappedTag = try! NSRegularExpression(
        pattern: #"^<([A-Za-z][A-Za-z0-9_-]*)\b[^>]*>([\s\S]*?)</\1>\s*$"#,
        options: []
    )

    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        for _ in 0..<3 {
            if matches(lonelyTag, text) {
                return nil
            }
            if let (tag, body) = unwrapTag(text), internalTagNames.contains(tag) {
                text = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { return nil }
                continue
            }
            if startsWithInternalOpenTag(text) {
                return nil
            }
            break
        }

        text = strip(ansiEscape, from: text)
        text = strip(bareAnsi, from: text)
        text = strip(imagePrefix, from: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let firstLine = text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else { return nil }

        if matches(hookEcho, firstLine) {
            return nil
        }
        return firstLine
    }

    private static func unwrapTag(_ text: String) -> (tag: String, body: String)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = wrappedTag.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3,
              let tagRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[tagRange]), String(text[bodyRange]))
    }

    private static func startsWithInternalOpenTag(_ text: String) -> Bool {
        guard text.hasPrefix("<") else { return false }
        for name in internalTagNames where text.hasPrefix("<\(name)") {
            return true
        }
        return false
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func strip(_ pattern: NSRegularExpression, from text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
