import Foundation

/// Tracks in-flight permission requests by `toolUseId` so the notch can
/// dedup a CLI re-emitting the same approval prompt, and own the rules for
/// when a downstream event (PostToolUse / Stop / SessionEnd) makes an
/// already-shown permission card stale and worth clearing.
///
/// State is only the dedup table; the "scan queue and remove" step stays in
/// the center, since that needs queue and timer access. This type owns the
/// pure decision (`shouldClearPermission`) and the table mutations.
struct PermissionRequestRegistry {
    private var pendingByToolUseId: [String: UUID] = [:]

    /// Register a permission request. Returns the existing event id when a
    /// duplicate (same `toolUseId`) is already in flight — caller should
    /// resolve the new event as `.ask` and let the existing card take it.
    /// Returns nil and inserts otherwise.
    ///
    /// Empty `toolUseId` is treated as "no dedup possible" (returns nil
    /// without inserting), matching the center's prior `!toolUseId.isEmpty`
    /// guard.
    mutating func register(toolUseId: String, eventId: UUID) -> UUID? {
        guard !toolUseId.isEmpty else { return nil }
        if let existing = pendingByToolUseId[toolUseId] {
            return existing
        }
        pendingByToolUseId[toolUseId] = eventId
        return nil
    }

    mutating func unregister(toolUseId: String) {
        guard !toolUseId.isEmpty else { return }
        pendingByToolUseId.removeValue(forKey: toolUseId)
    }

    /// Pure judgment: should `candidate` (a permissionRequest in flight) be
    /// cleared from the queue because `trigger` (a PostToolUse / Stop /
    /// SessionEnd) just resolved its underlying tool? Provider+session must
    /// match. Stop/StopFailure/SessionEnd clear unconditionally; otherwise
    /// match by `toolUseId` if both have one, else by tool name.
    static func shouldClearPermission(candidate: AttentionEvent, becauseOf trigger: AttentionEvent) -> Bool {
        guard case .permissionRequest(let permissionTool, _, let permissionToolUseId, _) = candidate.kind else {
            return false
        }
        guard candidate.provider == trigger.provider,
              candidate.sessionId == trigger.sessionId else {
            return false
        }

        if trigger.rawEventName == "Stop"
            || trigger.rawEventName == "StopFailure"
            || trigger.rawEventName == "SessionEnd" {
            return true
        }

        let triggerToolUseId = trigger.toolUseId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTriggerToolUseId = (triggerToolUseId?.isEmpty == false) ? triggerToolUseId : nil
        if let normalizedTriggerToolUseId, !permissionToolUseId.isEmpty {
            return permissionToolUseId == normalizedTriggerToolUseId
        }

        guard let triggerTool = trigger.toolName?.lowercased() else { return false }
        return permissionTool.lowercased() == triggerTool
    }
}
