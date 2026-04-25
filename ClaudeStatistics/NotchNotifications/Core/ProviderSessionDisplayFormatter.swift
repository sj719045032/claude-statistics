import Foundation

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

    var displayMode: ProviderSessionDisplayMode {
        .forProvider(session.provider)
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
                    DisplayTextClassifier.prettyToolName(session.approvalToolName ?? session.provider.displayName)
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

}
