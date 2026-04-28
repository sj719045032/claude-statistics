import Foundation

/// Shared AppleScript-string-building primitives used by the
/// `TerminalAppleScriptContainsProbing` capability implementations
/// and `AppleScriptFocuser`. Lives in its own file (rather than as
/// `AppleScriptFocuser.private static`) so each AppleScript-able
/// terminal capability can compose its own `containsSessionScript`
/// without depending on focuser internals.
enum AppleScriptHelpers {
    /// Escape backslashes and double quotes so the value is safe to
    /// embed inside a `"…"` AppleScript string literal.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// AppleScript list literal of every accepted form of a tty path
    /// (`/dev/ttys001`, `ttys001`, …) so a `contains` check matches
    /// regardless of whether the terminal reports tty with the
    /// `/dev/` prefix or not.
    static func ttyListLiteral(_ tty: String) -> String {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        let values = [tty, trimmed, "/dev/\(trimmed)"]
        let unique = Array(Set(values)).sorted()
        return "{\(unique.map { "\"\(escape($0))\"" }.joined(separator: ", "))}"
    }

    /// AppleScript list literal of every accepted form of a project
    /// path (raw, standardized, with/without trailing slash, file://
    /// URL form). Returns `"{}"` for nil/empty so the calling script
    /// can compare safely without conditional clauses.
    static func pathListLiteral(_ projectPath: String?) -> String {
        guard let projectPath, !projectPath.isEmpty else { return "{}" }
        let raw = (projectPath as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: raw).standardizedFileURL.path
        let trimmed = trimTrailingSlash(standardized)
        let encoded = URL(fileURLWithPath: trimmed).absoluteString
        let values = [raw, standardized, trimmed, "\(trimmed)/", encoded]
        let unique = Array(Set(values.map(trimTrailingSlash))).sorted()
        return "{\(unique.map { "\"\(escape($0))\"" }.joined(separator: ", "))}"
    }

    private static func trimTrailingSlash(_ value: String) -> String {
        guard value.count > 1, value.hasSuffix("/") else { return value }
        return String(value.dropLast())
    }
}
