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

enum AttentionKind: Equatable {
    case permissionRequest(tool: String, input: [String: JSONValue], toolUseId: String)
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
    let tty: String?
    let pid: Int32?
    let terminalName: String?
    let terminalSocket: String?
    let terminalWindowID: String?
    let terminalTabID: String?
    let terminalStableID: String?
    let receivedAt: Date
    let kind: AttentionKind
    var pending: PendingResponse?

    static func == (lhs: AttentionEvent, rhs: AttentionEvent) -> Bool {
        lhs.id == rhs.id
    }
}

extension AttentionEvent {
    func withResolvedPermissionToolUseId(_ resolvedToolUseId: String) -> AttentionEvent {
        guard case .permissionRequest(let tool, let input, let currentToolUseId) = kind,
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
            tty: tty,
            pid: pid,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            terminalStableID: terminalStableID,
            receivedAt: receivedAt,
            kind: .permissionRequest(tool: tool, input: input, toolUseId: resolvedToolUseId),
            pending: pending
        )
    }

    var livePrompt: String? {
        guard rawEventName == "UserPromptSubmit" else { return nil }
        return Self.normalizePreview(message)
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
            return rawEventName == "Notification" && notificationType == "idle_prompt"
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
