import Foundation
import SwiftUI

/// Coarse runtime status of a session, used to color the peek-row badge dot.
enum ActiveSessionStatus: String, Codable {
    case running    // actively executing tools or thinking
    case approval   // waiting for the user to approve a tool
    case waiting    // Claude asked the user for input (idle_prompt / Stop)
    case done       // latest task ended cleanly
    case failed     // latest turn ended with an error
    case idle       // no recent signal — stale
}

enum CurrentOperationKind: String, Codable {
    case tool
    case compacting
    case compressing
    case modelThinking
    case toolSelection
    case subagent
    case genericProcessing
}

struct CurrentOperation: Codable, Equatable {
    let kind: CurrentOperationKind
    let text: String
    let symbol: String
    let startedAt: Date
    let toolName: String?
    let toolUseId: String?
    var semanticKey: String? = nil

    var isGenericFallback: Bool {
        kind == .genericProcessing
    }

    var keepsSessionRunning: Bool {
        switch kind {
        case .tool, .compacting, .compressing, .modelThinking, .toolSelection, .subagent:
            return true
        case .genericProcessing:
            return false
        }
    }
}

enum ToolOutputKind: String, Codable {
    case result
    case echo
    case rawSnippet
}

struct ToolOutputSummary: Codable, Equatable {
    let text: String
    let kind: ToolOutputKind
    var semanticKey: String? = nil
}

/// One tool call in flight, keyed by toolUseId in `activeTools`. Lets the row
/// aggregate "Reading 3 files · Searching 2 patterns" across parent + subagent
/// activity instead of flipping between whichever `currentToolName` happened
/// to fire last.
struct ActiveToolEntry: Codable, Equatable {
    let toolName: String
    let detail: String?
    let startedAt: Date
}

/// Afterglow entry: a tool that just finished. Kept in `recentlyCompletedTools`
/// for a short window so sub-second tools (Read/Grep) don't merely flash past
/// in the detailed row — the user sees "✓ Read foo.swift 3s ago" instead of a
/// blank gap between PreToolUse and PostToolUse.
struct CompletedToolEntry: Codable, Equatable {
    let toolName: String
    let detail: String?
    let startedAt: Date
    let completedAt: Date
    let failed: Bool
}

struct ActiveSession: Identifiable, Equatable {
    // Was 300s — too forgiving once you've already approved. Post-approval
    // events sometimes can't clear the flag (toolUseId mismatch in subagent
    // storms), so a shorter stale window keeps the "approval" label from
    // lingering after the real moment has passed.
    static let approvalStaleInterval: TimeInterval = 60

    let id: String
    let sessionId: String
    let provider: ProviderKind
    let projectName: String
    let projectPath: String?
    let currentActivity: String?
    let currentActivitySemanticKey: String?
    let latestProgressNote: String?
    let latestProgressNoteAt: Date?
    let latestPrompt: String?
    let latestPromptAt: Date?
    let latestPreview: String?
    let latestPreviewAt: Date?
    let lastActivityAt: Date
    let currentOperation: CurrentOperation?
    let tty: String?
    let pid: Int32?
    let terminalName: String?
    let terminalSocket: String?
    let terminalWindowID: String?
    let terminalTabID: String?
    let terminalStableID: String?
    var status: ActiveSessionStatus = .idle
    /// Most recent tool output snippet — set on PostToolUse with a brief
    /// summary (e.g. "Bash[bg]: pulled image v1.0", "Task: review complete").
    /// Surfaced in the IdlePeekCard row so the user can see what background
    /// shells / subagents are producing without opening the terminal.
    var latestToolOutput: String? = nil
    var latestToolOutputSummary: ToolOutputSummary? = nil
    var latestToolOutputAt: Date? = nil
    /// Tool name that produced `latestToolOutput`, used to pick the right
    /// SF Symbol icon when rendering.
    var latestToolOutputTool: String? = nil
    /// Tool currently mid-execution (set on PreToolUse, cleared on PostToolUse
    /// for the matching toolUseId). nil when the session is just thinking.
    var currentToolName: String? = nil
    /// Short argument/target summary for the currently running tool.
    var currentToolDetail: String? = nil
    /// When the current tool started — used to display elapsed runtime.
    var currentToolStartedAt: Date? = nil
    /// Tool approval currently awaiting a user decision. Kept separate from
    /// `status` so a later notification/preview update cannot erase it.
    var approvalToolName: String? = nil
    var approvalToolDetail: String? = nil
    var approvalStartedAt: Date? = nil
    var approvalToolUseId: String? = nil
    /// How many background bash shells have been launched in this session.
    /// Approximate (no lifecycle hook for natural exit) — decays with session
    /// inactivity rather than per-shell tracking.
    var backgroundShellCount: Int = 0
    /// How many subagents are currently running (incremented on SubagentStart,
    /// decremented on SubagentStop).
    var activeSubagentCount: Int = 0
    /// Every tool call currently in flight across parent + subagents on this
    /// session, keyed by toolUseId. Populated on PreToolUse, cleared on
    /// PostToolUse/PostToolUseFailure for the matching toolUseId, and fully
    /// reset on Stop/StopFailure/SessionEnd.
    var activeTools: [String: ActiveToolEntry] = [:]
    /// Newest-first capped buffer of tools that just left `activeTools`. UI
    /// shows them in a dimmer style with "Ns ago" to keep sub-second tools
    /// visible instead of merely flashing past.
    var recentlyCompletedTools: [CompletedToolEntry] = []
    static let recentToolsMaxCount = 5
    // 20s chosen so the MIDDLE aggregate ("Reading 2 files · Running 1
    // command") stays populated across the usual between-tool gap when
    // Claude is generating reasoning text between tool calls. Shorter and
    // the row flickers to "Thinking…" briefly; much longer and the "finished
    // Xs ago" trailing in the detailed section starts to feel stale.
    static let recentToolsWindow: TimeInterval = 20

    var relativeActivityDescription: String {
        let elapsed = Int(Date().timeIntervalSince(lastActivityAt))
        if elapsed < 60     { return "\(elapsed)s ago" }
        if elapsed < 3600   { return "\(elapsed / 60)m ago" }
        return "\(elapsed / 3600)h ago"
    }

    /// Compact "12s" / "1m23s" / "1h2m" elapsed of the current tool, or nil
    /// if no tool is active.
    func currentToolElapsedText(at now: Date = Date()) -> String? {
        guard let started = currentToolStartedAt else { return nil }
        let secs = Int(max(0, now.timeIntervalSince(started)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 {
            let m = secs / 60, s = secs % 60
            return s == 0 ? "\(m)m" : "\(m)m\(s)s"
        }
        let h = secs / 3600, m = (secs % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    /// SF Symbol name for a Claude Code tool, used to draw a flat icon next to
    /// the tool name / output snippet.
    static func toolSymbol(_ rawTool: String?) -> String {
        switch (rawTool ?? "").lowercased() {
        case "bash":                       return "terminal"
        case "bashoutput":                 return "text.alignleft"
        case "killshell":                  return "stop.circle"
        case "task", "agent":              return "wand.and.stars"
        case "read":                       return "doc.text"
        case "write":                      return "square.and.pencil"
        case "edit", "multiedit":          return "pencil.line"
        case "grep":                       return "magnifyingglass"
        case "glob":                       return "folder"
        case "webfetch":                   return "arrow.down.circle"
        case "websearch", "web_search":    return "globe"
        case "todowrite":                  return "checklist"
        case "notebookedit":               return "book"
        default:                           return "wrench.and.screwdriver"
        }
    }

    var focusKey: String {
        "\(provider.rawValue):\(sessionId)"
    }

    var hasFocusHint: Bool {
        pid != nil
            || terminalStableID != nil
            || terminalTabID != nil
            || terminalWindowID != nil
            || tty != nil
            || !(projectPath ?? "").isEmpty
    }

    var canFocusBack: Bool {
        pid != nil
            || terminalStableID != nil
            || terminalTabID != nil
            || terminalWindowID != nil
            || tty != nil
    }

    var displayTitle: String {
        let raw = projectName.isEmpty ? (projectPath ?? sessionId) : projectName
        let expanded = (raw as NSString).expandingTildeInPath
        let last = (expanded as NSString).lastPathComponent
        return last.isEmpty ? raw : last
    }

    var previewLine: String? {
        guard let latestPreview else { return nil }
        let trimmed = latestPreview
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Primary operation copy for the idle row. Prefer the humanized runtime
    /// activity ("Reading foo.swift…", "Running: diff -u …") over raw tool
    /// identifiers so the row reads like a lightweight status panel rather
    /// than a debug inspector.
    var operationLineText: String? {
        displayContent.operationLineText
    }

    /// Secondary supporting line under the current operation.
    var supportingLineText: String? {
        displayContent.supportingLineText
    }

    var operationLineSymbol: String {
        displayContent.operationLineSymbol
    }

    var displayToolSymbol: String {
        currentOperation?.symbol
            ?? ActiveSession.toolSymbol(approvalToolName ?? currentToolName ?? latestToolOutputTool)
    }

    var supportingLineSymbol: String {
        displayContent.supportingLineSymbol
    }

    /// Triptych payload exposed to the row view. Each sub-field is guaranteed
    /// non-empty (formatter applies static fallbacks), so the UI never needs
    /// to guard for optionals. Simple and detailed modes share this content;
    /// detailed mode just renders an additional tool-list section beneath.
    var triptychContent: ProviderSessionDisplayContent {
        ProviderSessionDisplayFormatter(session: self).content
    }

    var displayStatus: ActiveSessionStatus {
        if hasFreshApproval {
            return .approval
        }
        return effectiveStatus
    }

    private var displayContent: ProviderSessionDisplayContent {
        ProviderSessionDisplayFormatter(session: self).content
    }

    /// Badge dot color reflecting session status. Fresh-looking bright colors
    /// for live states, muted provider color as fallback.
    var statusDotColor: Color {
        switch displayStatus {
        case .running: return Color(red: 0.40, green: 0.78, blue: 0.45)   // green
        case .approval: return Color(red: 0.98, green: 0.72, blue: 0.20)  // amber
        case .waiting: return Color(red: 0.98, green: 0.72, blue: 0.20)   // amber
        case .done:    return Color(red: 0.42, green: 0.70, blue: 1.00)   // blue
        case .failed:  return Color(red: 0.95, green: 0.35, blue: 0.35)   // red
        case .idle:    return provider.badgeColor.opacity(0.5)
        }
    }

    /// Downgrade stale runtime statuses — if nothing has happened for a while,
    /// treat the session as idle regardless of the last known event.
    ///
    /// `.running` has no time-based downgrade: the tracker flips it to
    /// done/failed/idle on Stop/StopFailure/SessionEnd, and the outer
    /// `pruneInactiveSessions` pass drops any session whose pid/terminal
    /// has disappeared. A staleness clock on top of that fires falsely
    /// during long Claude thinking windows (no hook events until the first
    /// tool) and long-running tools (PreToolUse → PostToolUse minutes apart
    /// with nothing in between). Previously this flipped the summary row to
    /// "Idle" while the detailed section was still showing live activity.
    private var effectiveStatus: ActiveSessionStatus {
        let elapsed = Date().timeIntervalSince(lastActivityAt)
        switch status {
        case .running:
            return .running
        case .approval:
            return elapsed < 300 ? .approval : .idle
        case .waiting:
            return elapsed < 300 ? .waiting : .idle   // waiting often lingers for minutes
        case .done, .failed:
            return elapsed < 120 ? status : .idle
        case .idle:
            return .idle
        }
    }

    private var hasFreshApproval: Bool {
        guard let started = approvalStartedAt else { return false }
        return Date().timeIntervalSince(started) < Self.approvalStaleInterval
    }
}
