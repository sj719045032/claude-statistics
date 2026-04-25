import Foundation

private enum ProviderSessionDisplayMode {
    case claude
    case codex
    case gemini

    static func forProvider(_ provider: ProviderKind) -> ProviderSessionDisplayMode {
        switch provider {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        }
    }
}

struct ProviderSessionDisplayContent {
    // Triptych: top = user's last prompt. Middle and bottom are action and
    // commentary in chronological order — the UI swaps them when commentary
    // happened before action (e.g. "Let me check…" → Read foo.swift). Each
    // cell has a stable non-empty text via static fallbacks.
    let promptText: String
    let promptSymbol: String
    let actionText: String
    let actionSymbol: String
    /// When the current action phase began. Used by the UI to decide whether
    /// action should be above or below commentary. nil when the action line
    /// is a pure status fallback with no real event behind it.
    let actionTimestamp: Date?
    let commentaryText: String
    let commentarySymbol: String
    /// When the latest agent reply was emitted. nil when commentary is a
    /// fallback ("Waiting for reply" / "Waiting for input").
    let commentaryTimestamp: Date?

    /// True when commentary happened before action and the UI should render
    /// commentary in MIDDLE and action in BOTTOM. Only fires when *both* sides
    /// have real timestamps — a fallback action (no timestamp) keeps its
    /// default MIDDLE slot so the row isn't dominated by a static phrase.
    ///
    /// The hook normalizer attaches the transcript entry's native timestamp
    /// to commentary so this comparison reflects the true wall-clock order,
    /// not just hook-fire order (which collapsed text-then-tool onto the
    /// same Date).
    var isChronologicallyReversed: Bool {
        guard let actionAt = actionTimestamp,
              let commentaryAt = commentaryTimestamp else { return false }
        return commentaryAt < actionAt
    }

    // Back-compat shims so call sites reading the old names keep working while
    // the UI migrates to the triptych layout. Remove once callers are updated.
    var operationLineText: String? { actionText }
    var operationLineSymbol: String { actionSymbol }
    var supportingLineText: String? { commentaryText }
    var supportingLineSymbol: String { commentarySymbol }
}

private struct SessionDisplayEntry {
    let text: String
    let symbol: String
    let semanticKey: String?
    let timestamp: Date?
    let order: Int
}

struct ProviderSessionDisplayFormatter {
    let session: ActiveSession

    var content: ProviderSessionDisplayContent {
        let prompt = resolvePromptLine()
        let action = resolveActionLine()
        let commentary = resolveCommentaryLine()
        return ProviderSessionDisplayContent(
            promptText: prompt.text,
            promptSymbol: prompt.symbol,
            actionText: action.text,
            actionSymbol: action.symbol,
            actionTimestamp: action.timestamp,
            commentaryText: commentary.text,
            commentarySymbol: commentary.symbol,
            commentaryTimestamp: commentary.timestamp
        )
    }

    // MARK: - Triptych resolvers (each returns a guaranteed non-empty line)

    private func resolvePromptLine() -> (text: String, symbol: String) {
        if let prompt = cleanDisplayText(session.latestPrompt) {
            return (prompt, "person.fill")
        }
        return (LanguageManager.localizedString("notch.triptych.noPromptYet"), "person.crop.circle.dashed")
    }

    private func resolveActionLine() -> (text: String, symbol: String, timestamp: Date?) {
        // activeToolsSummary goes first so concurrent work surfaces as an
        // aggregate ("Searching 2 patterns · Reading 1 file") instead of the
        // "last PreToolUse" snapshot swallowing the count. Its own guard
        // returns nil for count ≤ 1, falling through to the single-tool paths.
        if let pick = firstDisplayLine(from: [
            activeToolsSummaryCandidate,
            currentOperationCandidate,
            currentActivityCandidate,
            currentToolDetailCandidate
        ]) {
            return (pick.text, pick.symbol, actionTimestamp)
        }
        let fallback = operationStaticFallback
        // Terminal-state fallbacks ("Task done" / "Failed" / "Idle" /
        // "Waiting for input") describe a state that began *after* any
        // commentary, so stamp them with `now`. That lets
        // `isChronologicallyReversed` swap the rows so the row reads
        // top-to-bottom as: prompt → commentary → terminal status.
        // `.running` ("Thinking…") and `.approval` keep a nil timestamp:
        // those are ongoing/concurrent with commentary, not strictly later,
        // and the UI prefers to keep the static phrase in MIDDLE rather
        // than displace fresh assistant text down to BOTTOM.
        let fallbackTimestamp: Date?
        switch session.displayStatus {
        case .done, .failed, .idle, .waiting:
            fallbackTimestamp = Date()
        case .running, .approval:
            fallbackTimestamp = nil
        }
        return (fallback.text, fallback.symbol, fallbackTimestamp)
    }

    /// When the current action phase began. Use the *latest* active tool
    /// start — a fire-and-forget tool like TaskUpdate (no PostToolUse ever
    /// clears it) leaves a stale entry in `activeTools` whose startedAt is
    /// earlier than later commentary. `.min()` would then flag commentary
    /// as "newer than action" and skip the chronological reversal that the
    /// triptych relies on.
    ///
    /// When no tool is actively tracked but `currentActivity` still has a
    /// lingering description (Claude's `clearsCurrentActivity` only fires
    /// on Stop / Notification, so Bash's PostToolUse leaves the text), fall
    /// back to `lastActivityAt` so the triptych row can still reason about
    /// ordering instead of silently skipping reverse.
    private var actionTimestamp: Date? {
        if let latest = session.activeTools.values.map(\.startedAt).max() {
            return latest
        }
        if let started = session.currentToolStartedAt ?? session.currentOperation?.startedAt {
            return started
        }
        // MIDDLE also represents just-finished afterglow entries ("Read 1 file"
        // right after the Read completed), so their completion time seeds the
        // timestamp comparison used by `isChronologicallyReversed`. Without
        // this, the triptych would silently skip reversal whenever Claude is
        // between tool calls.
        let cutoff = Date().addingTimeInterval(-ActiveSession.recentToolsWindow)
        if let latestRecent = session.recentlyCompletedTools
            .filter({ $0.completedAt >= cutoff })
            .map(\.completedAt)
            .max() {
            return latestRecent
        }
        // `currentActivity` may still hold a tool-derived activity string
        // (provider hooks that set it directly rather than via PreToolUse
        // don't get cleared on PostToolUse). Use `lastActivityAt` as a coarse
        // proxy so the triptych can still order it relative to commentary.
        if let activity = session.currentActivity,
           !activity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.lastActivityAt
        }
        return nil
    }

    /// BOTTOM line is MIDDLE's supplementary detail, strictly scoped to the
    /// current turn. An old agent reply from a previous exchange must *not*
    /// appear under a brand-new user prompt — that would flip the top-to-bottom
    /// "early → late" time order the user relies on to read the row.
    ///
    /// Priority:
    ///   1. Approval state  → the command awaiting approval
    ///   2. Current-turn commentary (timestamp ≥ latest prompt)
    ///   3. Static fallback, context-aware:
    ///      • fresh session (no prompt)  → "Waiting for input" (user hasn't spoken)
    ///      • prompt present, no reply   → "Waiting for reply" (Claude hasn't answered)
    private func resolveCommentaryLine() -> (text: String, symbol: String, timestamp: Date?) {
        if session.displayStatus == .approval,
           let detail = cleanDisplayText(session.approvalToolDetail) {
            return (detail, "terminal", session.approvalStartedAt)
        }
        if let note = cleanDisplayText(session.latestProgressNote),
           isCurrentTurnCommentary() {
            return (note, "sparkles", session.latestProgressNoteAt)
        }
        let fallbackKey = session.latestPrompt == nil
            ? "notch.triptych.waitingForInput"
            : "notch.triptych.waitingForReply"
        return (LanguageManager.localizedString(fallbackKey), "ellipsis.bubble", nil)
    }

    /// `latestProgressNote` belongs to the current turn iff its timestamp
    /// lands on or after the latest user prompt. A brand-new `UserPromptSubmit`
    /// makes every prior commentary "past-turn" and therefore invisible here.
    /// If the session has no prompt yet (fresh open), anything we have is by
    /// definition current.
    private func isCurrentTurnCommentary() -> Bool {
        guard let commentaryAt = session.latestProgressNoteAt else { return false }
        guard let promptAt = session.latestPromptAt else { return true }
        return commentaryAt >= promptAt
    }

    private var displayMode: ProviderSessionDisplayMode {
        .forProvider(session.provider)
    }

    private var defaultOperationSymbol: String {
        session.currentOperation?.symbol
            ?? ActiveSession.toolSymbol(session.approvalToolName ?? session.currentToolName ?? session.latestToolOutputTool)
    }

    private var latestPreviewCandidate: (text: String?, symbol: String) {
        switch displayMode {
        case .codex, .gemini:
            return (commandFilteredPreviewLine, "sparkles")
        case .claude:
            return (session.previewLine, "sparkles")
        }
    }

    private var latestProgressNoteCandidate: (text: String?, symbol: String) {
        (session.latestProgressNote, "sparkles")
    }

    /// Row 2 static fallback: a short status phrase derived from displayStatus.
    /// Guarantees the operation line is never empty — ever.
    private var operationStaticFallback: (text: String, symbol: String) {
        switch session.displayStatus {
        case .running:
            return (LanguageManager.localizedString("notch.status.thinking"), "hourglass")
        case .approval:
            return (
                String(
                    format: LanguageManager.localizedString("notch.compact.permission"),
                    Self.prettyToolName(session.approvalToolName ?? session.provider.displayName)
                ),
                "lock.fill"
            )
        case .waiting:
            return (LanguageManager.localizedString("notch.status.waitingForInput"), "return")
        case .done:
            return (LanguageManager.localizedString("notch.status.taskDone"), "checkmark.circle")
        case .failed:
            return (LanguageManager.localizedString("notch.compact.failed"), "exclamationmark.triangle")
        case .idle:
            return (LanguageManager.localizedString("notch.status.idle"), "moon.zzz")
        }
    }

    /// Row 3 static fallback: relative time since the session's `lastActivityAt`.
    /// Derived purely from the session object, so it's available even when the
    /// event stream has been quiet for a while.
    private var supportingStaticFallback: (text: String, symbol: String) {
        let elapsed = max(0, Date().timeIntervalSince(session.lastActivityAt))
        let phrase: String
        if elapsed < 60 {
            phrase = "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            phrase = "\(Int(elapsed) / 60)m"
        } else {
            phrase = "\(Int(elapsed) / 3600)h"
        }
        return (
            String(
                format: LanguageManager.localizedString("notch.status.lastActivityAgo"),
                phrase
            ),
            "clock"
        )
    }

    private var latestPromptCandidate: (text: String?, symbol: String) {
        (session.latestPrompt, "person.fill")
    }

    private var latestToolOutputCandidate: (text: String?, symbol: String) {
        guard session.latestToolOutputSummary?.kind != .echo else {
            return (nil, ActiveSession.toolSymbol(session.latestToolOutputTool))
        }
        return (
            filteredToolOutputText(session.latestToolOutputSummary?.text ?? session.latestToolOutput),
            ActiveSession.toolSymbol(session.latestToolOutputTool)
        )
    }

    private var currentActivityCandidate: (text: String?, symbol: String) {
        (preferredCurrentActivityText, defaultOperationSymbol)
    }

    private var currentOperationCandidate: (text: String?, symbol: String) {
        (preferredCurrentOperationText, session.currentOperation?.symbol ?? defaultOperationSymbol)
    }

    /// "Reading 3 files · Searching 2 patterns · Running 1 command" style
    /// aggregate computed from the in-flight tool set plus the afterglow
    /// window of just-finished entries. Fires at any count >= 1 so MIDDLE
    /// reads as a consistent summary whenever anything has been happening,
    /// and the detailed-mode tool list below (when present) owns the
    /// per-target specifics.
    private var activeToolsSummaryCandidate: (text: String?, symbol: String) {
        let text = Self.aggregateActiveToolsText(
            active: session.activeTools,
            recent: session.recentlyCompletedTools
        )
        let symbol = session.activeSubagentCount > 0 ? "wand.and.stars" : "wrench.and.screwdriver"
        return (text, symbol)
    }

    private static func aggregateActiveToolsText(
        active: [String: ActiveToolEntry],
        recent: [CompletedToolEntry]
    ) -> String? {
        let cutoff = Date().addingTimeInterval(-ActiveSession.recentToolsWindow)
        let freshRecent = recent.filter { $0.completedAt >= cutoff }

        var buckets: [String: Int] = [:]
        for entry in active.values {
            let canonical = CanonicalToolName.resolve(entry.toolName)
            buckets[canonical, default: 0] += 1
        }
        for entry in freshRecent {
            let canonical = CanonicalToolName.resolve(entry.toolName)
            buckets[canonical, default: 0] += 1
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

    private static func phraseForBucket(tool: String, count: Int) -> String {
        let key: String
        switch tool {
        case "read":                            key = "notch.activeTools.reading"
        case "edit", "multiedit":               key = "notch.activeTools.editing"
        case "write":                           key = "notch.activeTools.writing"
        case "grep":                            key = "notch.activeTools.searching"
        case "glob":                            key = "notch.activeTools.globbing"
        case "bash", "bashoutput":              key = "notch.activeTools.running"
        case "task", "agent":                   key = "notch.activeTools.delegating"
        case "websearch", "web_search":         key = "notch.activeTools.websearching"
        case "webfetch", "fetch":               key = "notch.activeTools.fetching"
        default:                                key = "notch.activeTools.generic"
        }
        let format = LanguageManager.localizedString(key)
        return String(format: format, locale: LanguageManager.currentLocale, count)
    }

    private var backgroundStartedCandidate: (text: String?, symbol: String) {
        // Shell count intentionally not surfaced here — Claude Code has no
        // natural-exit hook for `run_in_background: true` bashes, so the
        // counter only increments. Surfacing it would claim "5 commands
        // running" long after those shells have exited.
        if session.activeSubagentCount > 1 {
            let format = LanguageManager.localizedString("notch.compact.backgroundAgentsRunning")
            return (String(format: format, locale: LanguageManager.currentLocale, session.activeSubagentCount), "wand.and.stars")
        }
        if session.activeSubagentCount == 1 {
            return (LanguageManager.localizedString("notch.compact.backgroundAgentStarted"), "wand.and.stars")
        }
        return (nil, defaultOperationSymbol)
    }

    private var currentToolDetailCandidate: (text: String?, symbol: String) {
        (filteredOperationText(session.currentToolDetail), defaultOperationSymbol)
    }

    private var approvalToolDetailCandidate: (text: String?, symbol: String) {
        (filteredOperationText(session.approvalToolDetail), defaultOperationSymbol)
    }

    private var fallbackCurrentActivityCandidate: (text: String?, symbol: String) {
        (session.currentActivity, defaultOperationSymbol)
    }

    private var preferredCurrentOperationText: String? {
        guard let operation = filteredOperationText(session.currentOperation?.text) else { return nil }
        guard !shouldPreferPreviewAsPrimary(over: operation) else { return nil }
        return operation
    }

    private var preferredCurrentActivityText: String? {
        guard let activity = filteredOperationText(session.currentActivity) else { return nil }
        guard !shouldPreferPreviewAsPrimary(over: activity) else { return nil }
        return activity
    }

    private var fallbackCurrentToolDetailCandidate: (text: String?, symbol: String) {
        (session.currentToolDetail, defaultOperationSymbol)
    }

    private var fallbackToolLabelCandidate: (text: String?, symbol: String) {
        (fallbackToolLabel, defaultOperationSymbol)
    }

    private var approvalLabelCandidate: (text: String?, symbol: String) {
        let rawTool = session.approvalToolName ?? session.currentToolName ?? session.latestToolOutputTool
        let label = Self.prettyToolName(rawTool ?? session.provider.displayName)
        return (
            String(format: LanguageManager.localizedString("notch.compact.permission"), label),
            "lock.fill"
        )
    }

    private var isOperationFocused: Bool {
        if session.currentToolName != nil
            || session.currentToolStartedAt != nil
            || session.activeSubagentCount > 0 {
            return true
        }

        if let operation = session.currentOperation,
           !operation.isGenericFallback,
           filteredOperationText(operation.text) != nil {
            return true
        }

        guard let activity = filteredOperationText(session.currentActivity) else { return false }
        return !Self.isGenericProcessingText(activity)
    }

    // Pre-triptych helpers (resolveOperationLine, resolveSupportingLine,
    // statusFallbackSupportingContent, and the per-status content builders)
    // have been removed — triptych resolvers above are the only path now.

    private var recentDialogueEntries: [SessionDisplayEntry] {
        var entries: [SessionDisplayEntry] = []

        if let note = cleanDisplayText(latestProgressNoteCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: note,
                symbol: latestProgressNoteCandidate.symbol,
                semanticKey: nil,
                timestamp: session.latestProgressNoteAt,
                order: 0
            ))
        }

        if let toolOutput = cleanDisplayText(latestToolOutputCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: toolOutput,
                symbol: latestToolOutputCandidate.symbol,
                semanticKey: session.latestToolOutputSummary?.semanticKey,
                timestamp: session.latestToolOutputAt,
                order: 1
            ))
        }

        if let prompt = cleanDisplayText(latestPromptCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: prompt,
                symbol: latestPromptCandidate.symbol,
                semanticKey: nil,
                timestamp: session.latestPromptAt,
                order: 2
            ))
        }

        if let preview = cleanDisplayText(latestPreviewCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: preview,
                symbol: latestPreviewCandidate.symbol,
                semanticKey: nil,
                timestamp: session.latestPreviewAt,
                order: 3
            ))
        }

        let sorted = entries.sorted(by: compareEntriesChronologically)
        var deduped: [SessionDisplayEntry] = []
        for entry in sorted {
            if let previous = deduped.last,
               isDuplicateDisplayEntry(previous, entry) {
                continue
            }
            deduped.append(entry)
        }
        return deduped
    }

    private func timelineSupportingCandidates(
        excluding operation: String?,
        semanticKey excludedSemanticKey: String? = nil
    ) -> [(text: String?, symbol: String)] {
        let excluded = operation.map(comparableDisplayKey(_:))
        return recentDialogueEntries
            .sorted(by: compareEntriesReverseChronologically)
            .compactMap { entry in
                if let excludedSemanticKey,
                   let entrySemanticKey = entry.semanticKey,
                   entrySemanticKey == excludedSemanticKey {
                    return nil
                }
                if let excluded, comparableDisplayKey(entry.text) == excluded {
                    return nil
                }
                return (text: entry.text, symbol: entry.symbol)
            }
    }

    private var commandFilteredPreviewLine: String? {
        guard let preview = session.previewLine else { return nil }
        return Self.isCommandLikeText(preview) ? nil : preview
    }

    private var fallbackToolLabel: String? {
        guard let tool = (session.approvalToolName ?? session.currentToolName)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !tool.isEmpty else { return nil }
        return Self.prettyToolName(tool)
    }


    private func firstDisplayLine(
        from candidates: [(text: String?, symbol: String)],
        excluding: String? = nil
    ) -> (text: String, symbol: String)? {
        let excluded = excluding.map(comparableDisplayKey(_:))

        for candidate in candidates {
            guard let value = cleanDisplayText(candidate.text) else { continue }
            if let excluded, comparableDisplayKey(value) == excluded { continue }
            return (value, candidate.symbol)
        }

        return nil
    }

    private func filteredOperationText(_ text: String?) -> String? {
        guard let text = cleanDisplayText(text) else { return nil }
        guard !Self.isRawToolLabel(text, toolName: session.approvalToolName ?? session.currentToolName) else { return nil }
        return text
    }

    private func filteredToolOutputText(_ text: String?) -> String? {
        guard let text = cleanDisplayText(text) else { return nil }
        guard !Self.isCodeLikeSnippet(text) else { return nil }
        return text
    }

    private func cleanDisplayText(_ text: String?) -> String? {
        guard let text = text?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !Self.isInternalMarkupValue(text),
              !Self.isNoiseValue(text, mode: displayMode) else { return nil }
        return text
    }

    private func comparableDisplayKey(_ text: String) -> String {
        text
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isDuplicateDisplayEntry(_ lhs: SessionDisplayEntry, _ rhs: SessionDisplayEntry) -> Bool {
        if let lhsKey = lhs.semanticKey, let rhsKey = rhs.semanticKey, lhsKey == rhsKey {
            return true
        }
        return comparableDisplayKey(lhs.text) == comparableDisplayKey(rhs.text)
    }

    private func operationSemanticKey(for operationText: String?) -> String? {
        guard let operationText else { return nil }
        let operationKey = comparableDisplayKey(operationText)

        if let currentOperation = session.currentOperation,
           comparableDisplayKey(currentOperation.text) == operationKey {
            return currentOperation.semanticKey
        }

        if let currentActivity = session.currentActivity,
           comparableDisplayKey(currentActivity) == operationKey {
            return session.currentActivitySemanticKey
        }

        return nil
    }

    private func shouldPreferPreviewAsPrimary(over activity: String) -> Bool {
        guard Self.isGenericProcessingText(activity) else { return false }
        guard session.currentToolName == nil,
              session.currentToolStartedAt == nil,
              session.activeSubagentCount == 0 else { return false }
        guard let preview = cleanDisplayText(latestPreviewCandidate.text) else { return false }
        return !preview.isEmpty
    }

    private func compareEntriesChronologically(_ lhs: SessionDisplayEntry, _ rhs: SessionDisplayEntry) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (l?, r?):
            if l != r { return l < r }
            return lhs.order < rhs.order
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.order < rhs.order
        }
    }

    private func compareEntriesReverseChronologically(_ lhs: SessionDisplayEntry, _ rhs: SessionDisplayEntry) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (l?, r?):
            if l != r { return l > r }
            return lhs.order < rhs.order
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.order < rhs.order
        }
    }

    private static func isNoiseValue(_ text: String, mode: ProviderSessionDisplayMode) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let genericNoise = normalized == "true"
            || normalized == "false"
            || normalized == "null"
            || normalized == "nil"
            || normalized == "text"
            || normalized == "---"
            || normalized == "--"
            || normalized == "..."
            || normalized == "…"
            || normalized.allSatisfy { !$0.isLetter && !$0.isNumber }
        if genericNoise { return true }
        if isJsonLikeBlob(normalized) { return true }

        switch mode {
        case .gemini:
            return normalized.hasPrefix("process group pgid:")
                || normalized.hasPrefix("background pids:")
        case .claude, .codex:
            return false
        }
    }

    // Raw JSON blobs leak into preview when hook payloads stringify an internal
    // object (Codex PreToolUse). Suppress them so the row isn't noise.
    private static func isJsonLikeBlob(_ normalizedText: String) -> Bool {
        let trimmed = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return false }
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        return trimmed.contains("\":")
    }

    private static func isInternalMarkupValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }

        if isStandaloneInternalTag(trimmed) {
            return true
        }

        return trimmed.contains("<task-notification>")
            || trimmed.contains("<task-id>")
            || trimmed.contains("<tool-use-id>")
            || trimmed.contains("<ide_opened_file>")
            || trimmed.contains("<command-message>")
            || trimmed.contains("<local-command-caveat>")
            || trimmed.contains("<system-reminder>")
    }

    private static func isStandaloneInternalTag(_ text: String) -> Bool {
        text.range(
            of: #"^<{1,2}/?[A-Za-z][A-Za-z0-9_-]*(\s+[^>]*)?>{1,2}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isRawToolLabel(_ text: String, toolName: String?) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }

        let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pretty = tool.map { prettyToolName($0).lowercased() }

        return normalized == tool
            || normalized == pretty
            || normalized == "bash"
            || normalized == "read"
            || normalized == "write"
            || normalized == "edit"
            || normalized == "multiedit"
            || normalized == "grep"
            || normalized == "glob"
            || normalized == "task"
            || normalized == "agent"
    }

    private static func prettyToolName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "bash": return "Command"
        case "read": return "Read"
        case "write": return "Write"
        case "edit", "multiedit": return "Edit"
        case "grep": return "Search"
        case "glob": return "Files"
        case "task", "agent": return "Agent"
        case "websearch", "web_search": return "Web Search"
        case "webfetch": return "Fetch"
        default:
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    private static func isGenericProcessingText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let localizedValues = [
            LanguageManager.localizedString("notch.operation.working"),
            LanguageManager.localizedString("notch.operation.thinking"),
            LanguageManager.localizedString("notch.operation.starting"),
            "working…",
            "thinking…",
            "starting…",
            "working...",
            "thinking...",
            "starting..."
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return localizedValues.contains(normalized)
    }

    private static func isPathLikeText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("://") else { return false }

        if normalized.hasPrefix("/") || normalized.hasPrefix("~/") {
            return true
        }

        let basename = (normalized as NSString).lastPathComponent
        let ext = (basename as NSString).pathExtension
        return normalized.contains("/") && !basename.isEmpty && !ext.isEmpty
    }

    private static func pathBasename(_ text: String) -> String? {
        guard isPathLikeText(text) else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        let basename = (expanded as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    private static func isCommandLikeText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lower = normalized.lowercased()
        if lower.hasPrefix("cd ")
            || lower.hasPrefix("git ")
            || lower.hasPrefix("go ")
            || lower.hasPrefix("docker ")
            || lower.hasPrefix("bash ")
            || lower.hasPrefix("python ")
            || lower.hasPrefix("cargo ")
            || lower.hasPrefix("npm ")
            || lower.hasPrefix("pnpm ")
            || lower.hasPrefix("yarn ")
            || lower.hasPrefix("make ")
            || lower.hasPrefix("gh ") {
            return true
        }

        return normalized.contains("&&")
            || normalized.contains(" 2>&1")
            || normalized.contains(" | ")
            || normalized.contains("--")
    }

    private static func isCodeLikeSnippet(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lower = normalized.lowercased()
        let codePrefixes = [
            "let ", "var ", "func ", "guard ", "if ", "else", "switch ", "case ",
            "return ", "private ", "fileprivate ", "internal ", "public ",
            "struct ", "class ", "enum ", "protocol ", "extension ", "@state ",
            "@mainactor", "import "
        ]
        if codePrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        if normalized.hasSuffix("{") || normalized == "}" {
            return true
        }

        if normalized.contains("->")
            || normalized.contains("::")
            || normalized.contains("?.")
            || normalized.contains(" ?? ")
            || normalized.contains("guard let ")
            || normalized.contains("if let ")
            || normalized.contains(" = ")
            || normalized.contains(": ")
            || normalized.contains("nil") {
            let looksLikeAssignment = normalized.range(
                of: #"^[A-Za-z_][A-Za-z0-9_\.]*\s*=\s*[A-Za-z_\(]"#,
                options: .regularExpression
            ) != nil
            let looksLikeDeclaration = normalized.range(
                of: #"^(let|var|func|guard|if|case|switch|return)\b"#,
                options: .regularExpression
            ) != nil
            if looksLikeAssignment || looksLikeDeclaration {
                return true
            }
        }

        return false
    }
}
