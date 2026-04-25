import Foundation

/// Pure translation from the hook wire protocol (`WireMessage`) to the
/// in-app event type (`AttentionEvent` + `AttentionKind`). No I/O — no
/// socket, no disk, no UI dispatch. The bridge owns those side effects;
/// this layer is just shape conversion and the per-event-name decision tree.
enum WireEventTranslator {
    /// Map the wire `event` string (plus `notification_type` for
    /// notifications) into the in-app `AttentionKind`. The summary string
    /// passed in is the kind-bearing message used by UI cards (taskDone /
    /// waitingInput / taskFailed / sessionStart).
    static func translateKind(
        event: String,
        notificationType: String?,
        summary: String?
    ) -> AttentionKind {
        switch event {
        case "PermissionRequest":
            return .permissionRequest(
                tool: "",
                input: [:],
                toolUseId: "",
                interaction: .actionable
            )
        case "ToolPermission":
            return .permissionRequest(
                tool: "",
                input: [:],
                toolUseId: "",
                interaction: .passive
            )
        case "StopFailure":
            return .taskFailed(summary: summary)
        case "Stop":
            // Claude finished its turn cleanly — surface as "task done".
            // The notification `idle_prompt` below (Claude proactively asks
            // the user something) stays as .waitingInput, since that's a
            // genuine "please respond" prompt.
            return .taskDone(summary: summary)
        case "SubagentStop":
            return .activityPulse
        case "SessionStart":
            return .sessionStart(source: summary)
        case "SessionEnd":
            return .sessionEnd
        case "Notification":
            switch notificationType {
            case "idle_prompt":
                return .waitingInput(message: summary)
            case "permission_prompt":
                return .activityPulse
            default:
                return .activityPulse
            }
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
             "SubagentStart", "PreCompact", "PostCompact":
            return .activityPulse
        default:
            return .activityPulse
        }
    }

    /// Map the wire `provider` string into the canonical enum. Anything
    /// other than "codex" / "gemini" defaults to `.claude` (matching the
    /// historical behavior of the bridge — Claude is the original provider
    /// and the wire format predates the multi-provider split).
    static func translateProvider(_ raw: String?) -> ProviderKind {
        switch raw {
        case "codex":  return .codex
        case "gemini": return .gemini
        default:       return .claude
        }
    }

    /// Build the full `AttentionEvent`, including all wire field copies and
    /// the kind/provider derivations. The bridge supplies the optional
    /// `pending` (for live socket connections that expect a reply) and
    /// resolved kind — the latter so the bridge can pass the
    /// permissionRequest case with proper toolUseId/input/tool plugged in.
    static func makeEvent(
        from msg: WireMessage,
        provider: ProviderKind,
        kind: AttentionKind,
        pending: PendingResponse?
    ) -> AttentionEvent {
        AttentionEvent(
            id: UUID(),
            provider: provider,
            rawEventName: msg.event,
            notificationType: msg.notification_type,
            toolName: msg.tool_name,
            toolInput: msg.tool_input,
            toolUseId: msg.tool_use_id,
            toolResponse: msg.tool_response,
            message: msg.message,
            sessionId: msg.session_id ?? "",
            projectPath: msg.cwd,
            transcriptPath: msg.transcript_path,
            tty: msg.tty,
            pid: msg.pid.map { Int32($0) },
            terminalName: msg.terminal_name,
            terminalSocket: msg.terminal_socket,
            terminalWindowID: msg.terminal_window_id,
            terminalTabID: msg.terminal_tab_id,
            terminalStableID: msg.terminal_surface_id,
            receivedAt: Date(),
            promptText: msg.prompt_text,
            commentaryText: msg.commentary_text,
            commentaryAt: msg.commentary_timestamp.flatMap(parseIsoTimestamp),
            kind: kind,
            pending: pending
        )
    }

    /// Resolve the permissionRequest case (which doesn't get tool/input
    /// info from `translateKind` alone) by overlaying values from the
    /// `WireMessage`. Returns the input kind unchanged if it isn't a
    /// permission request.
    static func resolvePermissionFields(_ kind: AttentionKind, in msg: WireMessage) -> AttentionKind {
        guard case .permissionRequest(_, _, _, let interaction) = kind else { return kind }
        return .permissionRequest(
            tool: msg.tool_name ?? "",
            input: msg.tool_input ?? [:],
            toolUseId: msg.tool_use_id ?? "",
            interaction: interaction
        )
    }

    /// Parse an ISO-8601 timestamp from the hook's `commentary_timestamp`
    /// field. The Claude transcript timestamps use fractional seconds + 'Z'
    /// (e.g. "2026-04-24T10:42:56.566Z"), which `ISO8601DateFormatter` can
    /// handle when told to include fractional seconds. Falls back to the
    /// non-fractional form for older transcript versions.
    static func parseIsoTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let d = fractionalIsoFormatter.date(from: trimmed) { return d }
        return isoFormatter.date(from: trimmed)
    }

    /// Short label for a JSONValue's kind, used by permission-schema logs.
    /// Arrays/objects include the element count so we can spot
    /// `edits: array(3)`.
    static func jsonKindLabel(_ value: JSONValue) -> String {
        switch value {
        case .string:             return "string"
        case .number:             return "number"
        case .bool:               return "bool"
        case .null:               return "null"
        case .array(let items):   return "array(\(items.count))"
        case .object(let dict):   return "object(\(dict.count))"
        }
    }

    private static let fractionalIsoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
