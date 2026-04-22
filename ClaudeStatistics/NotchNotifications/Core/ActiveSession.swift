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

struct ActiveSession: Identifiable, Equatable {
    static let approvalStaleInterval: TimeInterval = 300

    let id: String
    let sessionId: String
    let provider: ProviderKind
    let projectName: String
    let projectPath: String?
    let currentActivity: String?
    let latestPrompt: String?
    let latestPromptAt: Date?
    let latestPreview: String?
    let latestPreviewAt: Date?
    let lastActivityAt: Date
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
        ActiveSession.toolSymbol(approvalToolName ?? currentToolName ?? latestToolOutputTool)
    }

    var supportingLineSymbol: String {
        displayContent.supportingLineSymbol
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
    private var effectiveStatus: ActiveSessionStatus {
        let elapsed = Date().timeIntervalSince(lastActivityAt)
        switch status {
        case .running:
            return elapsed < 30 ? .running : .idle
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
