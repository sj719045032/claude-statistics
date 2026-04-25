import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

enum ApprovalRequestInteraction: String, Equatable, Sendable {
    case actionable
    case passive
}

enum AttentionKind: Equatable {
    case permissionRequest(tool: String, input: [String: JSONValue], toolUseId: String, interaction: ApprovalRequestInteraction)
    case taskFailed(summary: String?)
    case waitingInput(message: String?)
    case taskDone(summary: String?)
    case sessionStart(source: String?)
    case activityPulse
    case sessionEnd

    var priority: Int {
        switch self {
        case .permissionRequest: return 1
        case .taskFailed:        return 2
        case .waitingInput:      return 3
        case .taskDone:          return 4
        case .sessionStart:      return 5
        case .activityPulse:     return 6
        case .sessionEnd:        return 7
        }
    }

    // Whether this kind should auto-dismiss after a short peek (no user action required).
    // `taskDone` gives enough time to read a short summary; hover on the notch
    // pauses the timer (handled in NotchNotificationCenter) so users reading
    // longer markdown get to finish before the card disappears.
    var autoDismissAfter: TimeInterval? {
        switch self {
        case .sessionStart: return 5.0
        case .taskDone:     return 10.0
        default:            return nil
        }
    }

    var isSilentTracking: Bool {
        switch self {
        case .activityPulse, .sessionEnd, .sessionStart:
            // sessionStart never pops a notch — the user just typed `claude`
            // themselves, so they know. The session still surfaces in the
            // IdlePeekCard's active-sessions list via runtime tracking.
            return true
        default:
            return false
        }
    }
}

enum Decision: String, Sendable {
    case allow, deny, ask
}

struct AttentionEvent: Identifiable, Equatable {
    let id: UUID
    let provider: ProviderKind
    let rawEventName: String
    let notificationType: String?
    let toolName: String?
    let toolInput: [String: JSONValue]?
    let toolUseId: String?
    let toolResponse: String?
    let message: String?
    let sessionId: String
    let projectPath: String?
    let transcriptPath: String?
    let tty: String?
    let pid: Int32?
    let terminalName: String?
    let terminalSocket: String?
    let terminalWindowID: String?
    let terminalTabID: String?
    let terminalStableID: String?
    let receivedAt: Date
    /// The user's typed prompt — set ONLY on UserPromptSubmit. Consumed by
    /// `livePrompt`. Kept in its own field so writes on one semantic lane
    /// (A: prompt) can never leak into another (B: commentary / C: status).
    let promptText: String?
    /// Claude's assistant text from the transcript tail-scan (semantic B).
    /// Written on any event whose normalizer has access to the transcript
    /// (PreToolUse / PostToolUse / Stop / StopFailure / Notification /
    /// PreCompact / PostCompact / Subagent* / SessionStart). Consumed by
    /// `liveProgressNote` — no `rawEventName` gating needed because the
    /// normalizer already decided when to populate it.
    let commentaryText: String?
    /// Transcript-native timestamp for `commentaryText`, letting the tracker
    /// write `latestProgressNoteAt` at when the text was actually written,
    /// not when the hook fired. Without this the triptych ordering collapses
    /// — PreToolUse's `receivedAt` equals the following tool's startedAt.
    let commentaryAt: Date?
    let kind: AttentionKind
    var pending: PendingResponse?

    static func == (lhs: AttentionEvent, rhs: AttentionEvent) -> Bool {
        lhs.id == rhs.id
    }
}

extension AttentionEvent {
    func withResolvedPermissionToolUseId(_ resolvedToolUseId: String) -> AttentionEvent {
        guard case .permissionRequest(let tool, let input, let currentToolUseId, let interaction) = kind,
              currentToolUseId.isEmpty,
              !resolvedToolUseId.isEmpty else {
            return self
        }

        return AttentionEvent(
            id: id,
            provider: provider,
            rawEventName: rawEventName,
            notificationType: notificationType,
            toolName: toolName,
            toolInput: toolInput,
            toolUseId: resolvedToolUseId,
            toolResponse: toolResponse,
            message: message,
            sessionId: sessionId,
            projectPath: projectPath,
            transcriptPath: transcriptPath,
            tty: tty,
            pid: pid,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            terminalStableID: terminalStableID,
            receivedAt: receivedAt,
            promptText: promptText,
            commentaryText: commentaryText,
            commentaryAt: commentaryAt,
            kind: .permissionRequest(tool: tool, input: input, toolUseId: resolvedToolUseId, interaction: interaction),
            pending: pending
        )
    }

    var approvalInteraction: ApprovalRequestInteraction? {
        guard case .permissionRequest(_, _, _, let interaction) = kind else { return nil }
        return interaction
    }

    var isActionableApproval: Bool { approvalInteraction == .actionable }

    var isPassiveApproval: Bool { approvalInteraction == .passive }

    var livePrompt: String? {
        // Single source: `promptText`. The normalizer writes it ONLY on
        // UserPromptSubmit, so we don't need a rawEventName guard here.
        Self.normalizePreview(promptText)
    }

    var liveProgressNote: String? {
        // Single source: `commentaryText`. The normalizer writes it on
        // every event that can carry an assistant text block, and NOT on
        // UserPromptSubmit (so a fresh user turn can't accidentally carry
        // the previous turn's commentary). No rawEventName branching here.
        Self.normalizePreview(commentaryText)
    }

    /// Transcript-native timestamp for `liveProgressNote`. nil when either
    /// the commentary field is empty or the normalizer had no better source
    /// than `receivedAt`; in that case the tracker falls back to receivedAt.
    var liveProgressNoteAt: Date? {
        guard liveProgressNote != nil else { return nil }
        return commentaryAt
    }

    var livePreview: String? {
        switch kind {
        case .waitingInput(let message),
             .taskDone(let message),
             .taskFailed(let message):
            return Self.normalizePreview(message)
        case .permissionRequest, .sessionStart, .activityPulse, .sessionEnd:
            return nil
        }
    }

    var liveActivitySummary: String? {
        ToolActivityFormatter.liveSummary(
            rawEventName: rawEventName,
            notificationType: notificationType,
            toolName: toolName,
            input: toolInput,
            provider: provider
        )
    }

    var clearsCurrentActivity: Bool {
        switch kind {
        case .waitingInput, .taskDone, .taskFailed, .sessionEnd:
            return true
        case .permissionRequest, .sessionStart, .activityPulse:
            return false
        }
    }

    private static func normalizePreview(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Normalize line endings and trim each line; drop leading empty lines
        // but PRESERVE subsequent line breaks so markdown structure survives.
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let firstIdx = lines.firstIndex(where: { !$0.isEmpty }) else { return nil }
        var kept = Array(lines[firstIdx...])
        while kept.last?.isEmpty == true { kept.removeLast() }
        let cleaned = kept.joined(separator: "\n")

        guard !cleaned.isEmpty else { return nil }
        if isGenericWaitingMessage(cleaned) || isInternalMarkupMessage(cleaned) {
            return nil
        }
        // No truncation — the card wraps long content in a scroll view so the
        // user can read everything without losing the tail.
        return cleaned
    }

    private static func isGenericWaitingMessage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("waiting for your input")
            || normalized.contains("is waiting for your input")
            || normalized == "awaiting your input"
            || normalized == "waiting for input"
    }

    private static func isInternalMarkupMessage(_ text: String) -> Bool {
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
}
