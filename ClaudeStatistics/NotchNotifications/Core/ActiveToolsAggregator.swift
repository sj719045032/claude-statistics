import Foundation

/// Builds the "Reading 3 files · Searching 2 patterns · Running 1 command"
/// aggregate string for the notch MIDDLE row, given the in-flight tool set
/// plus the afterglow window of just-finished entries. Pure transformation —
/// no `ActiveSession` dependency, only the tool entry types — so it can be
/// unit-tested directly.
enum ActiveToolsAggregator {
    /// Returns the joined phrase, or `nil` when nothing has been happening
    /// inside the recent window.
    static func aggregateText(
        active: [String: ActiveToolEntry],
        recent: [CompletedToolEntry]
    ) -> String? {
        let cutoff = Date().addingTimeInterval(-ActiveSession.recentToolsWindow)
        let freshRecent = recent.filter { $0.completedAt >= cutoff }

        var buckets: [String: Int] = [:]
        for entry in active.values {
            let bucket = bucketKey(toolName: entry.toolName, detail: entry.detail)
            buckets[bucket, default: 0] += 1
        }
        for entry in freshRecent {
            let bucket = bucketKey(toolName: entry.toolName, detail: entry.detail)
            buckets[bucket, default: 0] += 1
        }

        let totalCalls = buckets.values.reduce(0, +)
        guard totalCalls > 0 else { return nil }

        let phrases = buckets
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { phraseForBucket(tool: $0.key, count: $0.value) }

        return phrases.joined(separator: " · ")
    }

    /// Maps an entry to its aggregate bucket. Bash entries get re-routed by
    /// their parsed command intent — `bash + grep …` joins the searching
    /// bucket with `Grep` calls, `bash + ls …` becomes a `listing` bucket,
    /// `bash + cat/sed/head/tail` joins the reading bucket with `Read`
    /// calls. This matches what Claude Code's own CLI shows ("Searching for
    /// 2 patterns, reading 1 file, listing 1 directory…") instead of
    /// flattening every shell call into a vague "Running N commands".
    ///
    /// Detection is by detail-string prefix because `ActiveToolEntry`
    /// doesn't preserve the raw command — `operationSummary(...)` already
    /// parsed the command into "Searching files" / "Listing /tmp" /
    /// "Reading foo.txt" / etc. via `shellCommandSummary`. Those phrases
    /// are hard-coded English in `ToolActivityFormatter`, so prefix
    /// matching is locale-stable.
    static func bucketKey(toolName: String, detail: String?) -> String {
        let canonical = CanonicalToolName.resolve(toolName)
        guard canonical == "bash" || canonical == "bashoutput", let detail else {
            return canonical
        }
        let trimmed = detail.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Searching") { return "grep" }
        if trimmed.hasPrefix("Finding")   { return "find" }
        if trimmed.hasPrefix("Listing")   { return "ls" }
        if trimmed.hasPrefix("Reading")   { return "read" }
        if trimmed.hasPrefix("Fetching")  { return "fetch" }
        return canonical
    }

    static func phraseForBucket(tool: String, count: Int) -> String {
        let key: String
        switch tool {
        case "read":                            key = "notch.activeTools.reading"
        case "edit", "multiedit":               key = "notch.activeTools.editing"
        case "write":                           key = "notch.activeTools.writing"
        case "grep":                            key = "notch.activeTools.searching"
        case "glob":                            key = "notch.activeTools.globbing"
        case "ls":                              key = "notch.activeTools.listing"
        case "find":                            key = "notch.activeTools.finding"
        case "bash", "bashoutput":              key = "notch.activeTools.running"
        case "task", "agent":                   key = "notch.activeTools.delegating"
        case "websearch", "web_search":         key = "notch.activeTools.websearching"
        case "webfetch", "fetch":               key = "notch.activeTools.fetching"
        default:                                key = "notch.activeTools.generic"
        }
        let format = LanguageManager.localizedString(key)
        return String(format: format, locale: LanguageManager.currentLocale, count)
    }
}
