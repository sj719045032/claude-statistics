import Foundation

/// Per-session runtime state maintained by `ActiveSessionsTracker`. Persisted
/// to disk by `RuntimeStatePersistor` so the notch can rebuild the active
/// list after a relaunch. Holds everything the UI might want to surface for
/// a session — current activity text, tool state, terminal locators, the
/// approval inbox — and projects to a UI-facing `ActiveSession` snapshot via
/// `activeSession`.
struct RuntimeSession: Codable, Equatable {
    let provider: ProviderKind
    var sessionId: String
    var projectPath: String?
    var currentActivity: String?
    var currentActivitySemanticKey: String? = nil
    var latestProgressNote: String? = nil
    var latestProgressNoteAt: Date? = nil
    var latestPrompt: String? = nil
    var latestPromptAt: Date? = nil
    var latestPreview: String?
    var latestPreviewAt: Date? = nil
    var currentOperation: CurrentOperation? = nil
    var tty: String?
    var pid: Int32?
    var terminalName: String?
    var terminalSocket: String?
    var terminalWindowID: String?
    var terminalTabID: String?
    var terminalStableID: String?
    var lastActivityAt: Date
    var status: ActiveSessionStatus = .idle
    var latestToolOutput: String? = nil
    var latestToolOutputSummary: ToolOutputSummary? = nil
    var latestToolOutputAt: Date? = nil
    var latestToolOutputTool: String? = nil
    var currentToolName: String? = nil
    var currentToolDetail: String? = nil
    var currentToolStartedAt: Date? = nil
    var currentToolUseId: String? = nil
    var approvalToolName: String? = nil
    var approvalToolDetail: String? = nil
    var approvalStartedAt: Date? = nil
    var approvalToolUseId: String? = nil
    var backgroundShellCount: Int = 0
    var activeSubagentCount: Int = 0
    var activeTools: [String: ActiveToolEntry] = [:]
    var recentlyCompletedTools: [CompletedToolEntry]? = nil
    var turnToolBucketCounts: [String: Int]? = nil
    var turnToolBucketCountsAt: Date? = nil

    var activeSession: ActiveSession {
        ActiveSession(
            id: "runtime:\(provider.rawValue):\(sessionId)",
            sessionId: sessionId,
            provider: provider,
            projectName: projectPath ?? sessionId,
            projectPath: projectPath,
            currentActivity: currentActivity,
            currentActivitySemanticKey: currentActivitySemanticKey,
            latestProgressNote: latestProgressNote,
            latestProgressNoteAt: latestProgressNoteAt,
            latestPrompt: latestPrompt,
            latestPromptAt: latestPromptAt,
            latestPreview: latestPreview,
            latestPreviewAt: latestPreviewAt,
            lastActivityAt: lastActivityAt,
            currentOperation: currentOperation,
            tty: tty,
            pid: pid,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            terminalStableID: terminalStableID,
            status: status,
            latestToolOutput: latestToolOutput,
            latestToolOutputSummary: latestToolOutputSummary,
            latestToolOutputAt: latestToolOutputAt,
            latestToolOutputTool: latestToolOutputTool,
            currentToolName: currentToolName,
            currentToolDetail: currentToolDetail,
            currentToolStartedAt: currentToolStartedAt,
            approvalToolName: approvalToolName,
            approvalToolDetail: approvalToolDetail,
            approvalStartedAt: approvalStartedAt,
            approvalToolUseId: approvalToolUseId,
            backgroundShellCount: backgroundShellCount,
            activeSubagentCount: activeSubagentCount,
            activeTools: activeTools,
            turnToolBucketCounts: turnToolBucketCounts,
            turnToolBucketCountsAt: turnToolBucketCountsAt,
            recentlyCompletedTools: recentlyCompletedTools
        )
    }
}
