import Foundation

/// Pure functions that fold an `AttentionEvent` (or transcript-derived
/// signals) into a `RuntimeSession`. The tracker owns lifecycle, focus
/// targeting, and persistence; this module owns the per-record state
/// machine that decides what fields each event mutates.
///
/// Five public entry points:
///
/// - `apply(event:to:)` — main switch on `event.rawEventName` covering
///   PreToolUse / PostToolUse / PermissionRequest / Stop / SessionEnd /
///   etc. Updates active tool slots, approval inbox, recently-completed
///   trail, background shell counter, current operation.
/// - `signals(from:stats:)` / `merge(runtime:signals:)` — fold transcript
///   parser output (progress notes, output previews, last prompt) into
///   the runtime, with timestamp / freshness rules.
/// - `formatToolOutput(for:)` — wrap `ToolActivityFormatter.toolOutputSummary`.
/// - `deriveStatus(for:rawName:previous:hadActiveOperation:)` — pick the
///   `ActiveSessionStatus` to surface in the UI for an event kind.
enum RuntimeSessionEventApplier {
    static func apply(event: AttentionEvent, to runtime: inout RuntimeSession) {
        if let nextOperation = ToolActivityFormatter.currentOperation(
            rawEventName: event.rawEventName,
            toolName: event.toolName,
            input: event.toolInput,
            provider: event.provider,
            receivedAt: event.receivedAt,
            toolUseId: event.toolUseId
        ) {
            runtime.currentOperation = nextOperation
        }

        switch event.rawEventName {
        case "PermissionRequest", "ToolPermission":
            let detail = operationSummary(for: event)
            runtime.currentToolName = event.toolName ?? runtime.currentToolName
            runtime.currentToolDetail = detail ?? runtime.currentToolDetail
            runtime.currentToolStartedAt = runtime.currentToolStartedAt ?? event.receivedAt
            if let toolUseId = event.toolUseId?.nilIfEmpty {
                runtime.currentToolUseId = toolUseId
            }
            runtime.approvalToolName = runtime.currentToolName ?? event.toolName
            runtime.approvalToolDetail = runtime.currentToolDetail ?? detail
            runtime.approvalStartedAt = event.receivedAt
            runtime.approvalToolUseId = event.toolUseId?.nilIfEmpty ?? runtime.currentToolUseId

        case "PreToolUse":
            clearApprovalIfFinished(runtime: &runtime, event: event)
            runtime.currentToolName = event.toolName
            runtime.currentToolDetail = operationSummary(for: event)
            runtime.currentToolStartedAt = event.receivedAt
            runtime.currentToolUseId = event.toolUseId
            if let id = event.toolUseId?.nilIfEmpty, let toolName = event.toolName?.nilIfEmpty {
                runtime.activeTools[id] = ActiveToolEntry(
                    toolName: toolName,
                    detail: operationSummary(for: event),
                    startedAt: event.receivedAt
                )
            }
            // Backgrounded bash is fire-and-forget on Claude Code's side.
            if event.toolName?.lowercased() == "bash", isBackgroundBash(input: event.toolInput) {
                runtime.backgroundShellCount += 1
            }

        case "PostToolUse", "PostToolUseFailure":
            clearApprovalIfFinished(runtime: &runtime, event: event)
            if let id = event.toolUseId?.nilIfEmpty {
                if let finished = runtime.activeTools.removeValue(forKey: id) {
                    let entry = CompletedToolEntry(
                        toolName: finished.toolName,
                        detail: finished.detail,
                        startedAt: finished.startedAt,
                        completedAt: event.receivedAt,
                        failed: event.rawEventName == "PostToolUseFailure"
                    )
                    runtime.recentlyCompletedTools.insert(entry, at: 0)
                    if runtime.recentlyCompletedTools.count > ActiveSession.recentToolsMaxCount {
                        runtime.recentlyCompletedTools = Array(
                            runtime.recentlyCompletedTools.prefix(ActiveSession.recentToolsMaxCount)
                        )
                    }
                }
            }
            // activeTools is the source of truth for "what's running". Once the
            // finished tool is gone from it, currentTool* and currentOperation
            // must not keep pointing at that tool — otherwise the MIDDLE row
            // lingers on a completed tool while the detailed section shows it
            // in "recent", and the row appears twice. Clear on toolUseId match
            // OR when activeTools no longer holds any entry for that tool name
            // (the latter covers events with dropped/missing toolUseId).
            let eventToolUseId = event.toolUseId?.nilIfEmpty
            let eventToolLower = event.toolName?.lowercased()
            let nameStillActive: Bool = {
                guard let eventToolLower else { return true }
                return runtime.activeTools.values.contains { $0.toolName.lowercased() == eventToolLower }
            }()
            let currentIdMatches = eventToolUseId != nil && runtime.currentToolUseId == eventToolUseId
            let currentNameStale = eventToolLower != nil
                && runtime.currentToolName?.lowercased() == eventToolLower
                && !nameStillActive
            if currentIdMatches || currentNameStale {
                runtime.currentToolName = nil
                runtime.currentToolDetail = nil
                runtime.currentToolStartedAt = nil
                runtime.currentToolUseId = nil
            }
            if runtime.currentOperation?.kind == .tool {
                let opIdMatches = runtime.currentOperation?.toolUseId?.nilIfEmpty == eventToolUseId
                let opToolLower = runtime.currentOperation?.toolName?.lowercased()
                let opNameStale = eventToolLower != nil
                    && opToolLower == eventToolLower
                    && !nameStillActive
                if opIdMatches || opNameStale {
                    runtime.currentOperation = nil
                }
            }
            // KillShell decrements background count.
            if event.toolName?.lowercased() == "killshell" {
                runtime.backgroundShellCount = max(0, runtime.backgroundShellCount - 1)
            }

        case "SubagentStart":
            runtime.activeSubagentCount += 1

        case "SubagentStop":
            runtime.activeSubagentCount = max(0, runtime.activeSubagentCount - 1)
            if runtime.currentOperation?.kind == .subagent {
                runtime.currentOperation = nil
            }

        case "PostCompact":
            if runtime.currentOperation?.kind == .compacting {
                runtime.currentOperation = nil
            }

        case "AfterModel":
            if runtime.currentOperation?.kind == .modelThinking {
                runtime.currentOperation = nil
            }

        case "UserPromptSubmit":
            // New user turn — everything tied to the previous exchange is now
            // past-turn and must not bleed into the triptych's MIDDLE/BOTTOM.
            // Approval, current tool, activeTools, recent trail, operation —
            // all reset. The BOTTOM row already filters commentary by
            // `latestProgressNoteAt >= latestPromptAt`, so we don't need to
            // clear `latestProgressNote` itself (timestamp-based filtering
            // hides it naturally, and keeping the field preserves it for the
            // parser-merge path that may arrive later).
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.currentOperation = nil
            runtime.activeTools.removeAll()
            runtime.recentlyCompletedTools.removeAll()

        case "Stop":
            // Turn ended — Claude can't be running a tool anymore.
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.currentOperation = nil
            runtime.activeTools.removeAll()
            runtime.recentlyCompletedTools.removeAll()

        case "StopFailure":
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.activeTools.removeAll()
            runtime.recentlyCompletedTools.removeAll()

        case "SessionEnd":
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.currentOperation = nil
            runtime.backgroundShellCount = 0
            runtime.activeSubagentCount = 0
            runtime.activeTools.removeAll()
            runtime.recentlyCompletedTools.removeAll()

        default:
            break
        }
    }

    static func signals(
        from quick: SessionQuickStats?,
        stats: SessionStats?
    ) -> [RuntimeSignal] {
        var signals: [RuntimeSignal] = []

        if let stats, let text = stats.latestProgressNote?.nilIfEmpty, let timestamp = stats.latestProgressNoteAt {
            signals.append(RuntimeSignal(kind: .progressNote, text: text, timestamp: timestamp))
        } else if let quick, let text = quick.latestProgressNote?.nilIfEmpty, let timestamp = quick.latestProgressNoteAt {
            signals.append(RuntimeSignal(kind: .progressNote, text: text, timestamp: timestamp))
        }

        if let stats, let text = stats.lastOutputPreview?.nilIfEmpty, let timestamp = stats.lastOutputPreviewAt {
            signals.append(RuntimeSignal(kind: .preview, text: text, timestamp: timestamp))
        } else if let quick, let text = quick.lastOutputPreview?.nilIfEmpty, let timestamp = quick.lastOutputPreviewAt {
            signals.append(RuntimeSignal(kind: .preview, text: text, timestamp: timestamp))
        }

        if let stats, let text = stats.lastPrompt?.nilIfEmpty, let timestamp = stats.lastPromptAt {
            signals.append(RuntimeSignal(kind: .prompt, text: text, timestamp: timestamp))
        } else if let quick, let text = quick.lastPrompt?.nilIfEmpty, let timestamp = quick.lastPromptAt {
            signals.append(RuntimeSignal(kind: .prompt, text: text, timestamp: timestamp))
        }

        return signals
    }

    static func merge(runtime: inout RuntimeSession, signals: [RuntimeSignal]) {
        for signal in signals.sorted(by: { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            switch (lhs.kind, rhs.kind) {
            case (.progressNote, .progressNote), (.preview, .preview), (.prompt, .prompt):
                return false
            case (.progressNote, _):
                return true
            case (_, .progressNote):
                return false
            case (.preview, _):
                return true
            case (_, .preview):
                return false
            }
        }) {
            switch signal.kind {
            case .progressNote:
                if shouldApply(
                    incomingText: signal.text,
                    incomingAt: signal.timestamp,
                    existingText: runtime.latestProgressNote,
                    existingAt: runtime.latestProgressNoteAt
                ) {
                    runtime.latestProgressNote = signal.text
                    runtime.latestProgressNoteAt = signal.timestamp
                    runtime.lastActivityAt = max(runtime.lastActivityAt, signal.timestamp)
                }
            case .preview:
                if shouldApply(
                    incomingText: signal.text,
                    incomingAt: signal.timestamp,
                    existingText: runtime.latestPreview,
                    existingAt: runtime.latestPreviewAt
                ) {
                    runtime.latestPreview = signal.text
                    runtime.latestPreviewAt = signal.timestamp
                    runtime.lastActivityAt = max(runtime.lastActivityAt, signal.timestamp)
                }
            case .prompt:
                if shouldApply(
                    incomingText: signal.text,
                    incomingAt: signal.timestamp,
                    existingText: runtime.latestPrompt,
                    existingAt: runtime.latestPromptAt
                ) {
                    runtime.latestPrompt = signal.text
                    runtime.latestPromptAt = signal.timestamp
                }
            }
        }
    }

    /// Extract a short, display-safe tool output summary for the active list.
    /// Prefer semantic summaries ("Read Foo.swift", "Searched: bar") over raw
    /// stdout snippets so the row feels like a live status panel, not a tail
    /// of terminal output.
    static func formatToolOutput(for event: AttentionEvent) -> ToolOutputSummary? {
        ToolActivityFormatter.toolOutputSummary(
            rawEventName: event.rawEventName,
            toolName: event.toolName,
            input: event.toolInput,
            response: event.toolResponse,
            toolUseId: event.toolUseId
        )
    }

    static func deriveStatus(
        for kind: AttentionKind,
        rawName: String,
        previous: ActiveSessionStatus,
        hadActiveOperation: Bool
    ) -> ActiveSessionStatus {
        switch kind {
        case .waitingInput:
            // idle_prompt can arrive while a tool approval/execution is still
            // active. In that case the tool state is the more truthful row.
            if hadActiveOperation {
                return previous == .approval ? .approval : .running
            }
            return .waiting
        case .taskFailed:
            return .failed
        case .taskDone:
            return .done
        case .permissionRequest:
            return .approval
        case .sessionStart:
            // A fresh session has not received a prompt yet — it is waiting for
            // the user, not running. UserPromptSubmit (activityPulse) flips it
            // to .running as soon as the user types. Falling through to
            // .waiting also means the 300s idle downgrade kicks in if the
            // window sits untouched, instead of staying green forever.
            return .waiting
        case .sessionEnd:
            return previous   // caller removes the runtime entry anyway
        case .activityPulse:
            // Any in-progress signal — PreToolUse, UserPromptSubmit, subagent
            // activity, compaction. These are silent-tracking so they never
            // surface a notch, but they DO mean the session is live.
            switch rawName {
            case "PreCompact", "PostCompact":
                return .running
            case "PostToolUse", "PostToolUseFailure", "SubagentStop":
                // Tool activity ended; if we were showing an approval wait,
                // clear that state so the row doesn't keep saying "approval".
                return previous == .idle || previous == .approval ? .running : previous
            default:
                return .running
            }
        }
    }

    // MARK: - Private

    private static func operationSummary(for event: AttentionEvent) -> String? {
        guard let tool = event.toolName, let input = event.toolInput else { return nil }
        return ToolActivityFormatter.operationSummary(tool: tool, input: input)
    }

    private static func shouldApply(
        incomingText: String,
        incomingAt: Date,
        existingText: String?,
        existingAt: Date?
    ) -> Bool {
        guard !incomingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let existingAt else { return true }
        if incomingAt > existingAt { return true }
        if incomingAt < existingAt { return false }
        return existingText?.caseInsensitiveCompare(incomingText) != .orderedSame
    }

    private static func clearApprovalIfFinished(runtime: inout RuntimeSession, event: AttentionEvent) {
        let eventToolUseId = event.toolUseId?.nilIfEmpty
        let approvalToolUseId = runtime.approvalToolUseId?.nilIfEmpty

        if let eventToolUseId, let approvalToolUseId {
            guard eventToolUseId == approvalToolUseId else { return }
        } else if let approvalTool = runtime.approvalToolName?.lowercased(),
                  let eventTool = event.toolName?.lowercased() {
            guard approvalTool == eventTool else { return }
        } else if runtime.approvalStartedAt == nil {
            return
        }

        runtime.approvalToolName = nil
        runtime.approvalToolDetail = nil
        runtime.approvalStartedAt = nil
        runtime.approvalToolUseId = nil
    }

    private static func isBackgroundBash(input: [String: JSONValue]?) -> Bool {
        guard let input, case .bool(let bg) = input["run_in_background"] else { return false }
        return bg
    }
}

enum RuntimeSignalKind {
    case progressNote
    case preview
    case prompt
}

struct RuntimeSignal {
    let kind: RuntimeSignalKind
    let text: String
    let timestamp: Date
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
