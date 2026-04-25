import Foundation

/// Candidate data sources for the triptych — each `*Candidate` derives a
/// `(text, symbol)` pair from `session` state. The orchestration layer in
/// the main file picks among these in priority order. Returning `(nil, _)`
/// means "skip me", which lets the orchestrator fall through to the next
/// candidate (or to the static fallback).
extension ProviderSessionDisplayFormatter {
    var defaultOperationSymbol: String {
        session.currentOperation?.symbol
            ?? ActiveSession.toolSymbol(session.approvalToolName ?? session.currentToolName ?? session.latestToolOutputTool)
    }

    var latestPreviewCandidate: (text: String?, symbol: String) {
        switch displayMode {
        case .codex, .gemini:
            return (commandFilteredPreviewLine, "sparkles")
        case .claude:
            return (session.previewLine, "sparkles")
        }
    }

    var latestProgressNoteCandidate: (text: String?, symbol: String) {
        (session.latestProgressNote, "sparkles")
    }

    var latestPromptCandidate: (text: String?, symbol: String) {
        (session.latestPrompt, "person.fill")
    }

    var latestToolOutputCandidate: (text: String?, symbol: String) {
        guard session.latestToolOutputSummary?.kind != .echo else {
            return (nil, ActiveSession.toolSymbol(session.latestToolOutputTool))
        }
        return (
            filteredToolOutputText(session.latestToolOutputSummary?.text ?? session.latestToolOutput),
            ActiveSession.toolSymbol(session.latestToolOutputTool)
        )
    }

    var currentActivityCandidate: (text: String?, symbol: String) {
        (preferredCurrentActivityText, defaultOperationSymbol)
    }

    var currentOperationCandidate: (text: String?, symbol: String) {
        (preferredCurrentOperationText, session.currentOperation?.symbol ?? defaultOperationSymbol)
    }

    /// "Reading 3 files · Searching 2 patterns · Running 1 command" style
    /// aggregate computed from the in-flight tool set plus the afterglow
    /// window of just-finished entries. Fires at any count >= 1 so MIDDLE
    /// reads as a consistent summary whenever anything has been happening,
    /// and the detailed-mode tool list below (when present) owns the
    /// per-target specifics.
    var activeToolsSummaryCandidate: (text: String?, symbol: String) {
        let text = ActiveToolsAggregator.aggregateText(
            active: session.activeTools,
            recent: session.recentlyCompletedTools
        )
        let symbol = session.activeSubagentCount > 0 ? "wand.and.stars" : "wrench.and.screwdriver"
        return (text, symbol)
    }

    var currentToolDetailCandidate: (text: String?, symbol: String) {
        (filteredOperationText(session.currentToolDetail), defaultOperationSymbol)
    }

    private var commandFilteredPreviewLine: String? {
        guard let preview = session.previewLine else { return nil }
        return DisplayTextClassifier.isCommandLikeText(preview) ? nil : preview
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
}
