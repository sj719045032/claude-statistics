import Foundation
import Combine

@MainActor
final class NotchNotificationCenter: ObservableObject {
    @Published private(set) var currentEvent: AttentionEvent?
    @Published private(set) var queuedCount: Int = 0
    @Published private(set) var currentAutoDismissDeadline: Date?

    weak var activeSessionsTracker: ActiveSessionsTracker?

    private var queue: [AttentionEvent] = []
    private var timeoutTimers: [UUID: DispatchSourceTimer] = [:]
    private var pendingByToolUseId: [String: UUID] = [:]   // dedup permission requests
    private var displayedWaitingSessionKeys: Set<String> = []
    private var lastInformationalAtBySession: [String: Date] = [:]
    // Session-scoped "Always allow" rules: keyed by "provider:sessionId:toolName"
    private var autoAllowRules: Set<String> = []
    func enqueue(_ event: AttentionEvent) {
        var event = event
        DiagnosticLogger.shared.info(
            "Notch enqueue start kind=\(describeKind(event.kind)) session=\(event.sessionId) toolUseId=\(event.toolUseId ?? "-") currentEvent=\(currentEvent.map { String($0.id.uuidString.prefix(8)) } ?? "nil") queueCount=\(queue.count)"
        )
        activeSessionsTracker?.record(event: event)
        event = enrichPermissionRequest(event)
        clearResolvedPermissionRequests(for: event)
        if event.kind.clearsWaitingInput {
            clearWaitingInput(for: event)
        }
        if case .sessionEnd = event.kind {
            clearAutoAllowRules(provider: event.provider, sessionId: event.sessionId)
        }
        if event.kind.isSilentTracking {
            DiagnosticLogger.shared.info("Notch drop: silent-tracking provider=\(event.provider.rawValue) kind=\(describeKind(event.kind)) raw=\(event.rawEventName)")
            event.pending?.resolve(.ask)
            return
        }

        // "Always allow" rule set by the user in a previous prompt — auto-approve silently.
        if case .permissionRequest(let tool, _, _) = event.kind,
           let key = autoAllowKey(provider: event.provider, sessionId: event.sessionId, toolName: tool),
           autoAllowRules.contains(key) {
            DiagnosticLogger.shared.info("Notch drop: auto-allow rule matched key=\(key)")
            event.pending?.resolve(.allow)
            return
        }

        // If the originating terminal surface is already focused, the user can
        // handle or read the event in-place. Keep the notch quiet even if a
        // permission batch or another card is already in flight.
        if isFocusSilenceEnabled(), isSessionFocused(for: event) {
            let ctx = activeSessionsTracker?.focusContext(for: event)
            DiagnosticLogger.shared.info(
                "Notch drop: terminal focus-silenced provider=\(event.provider.rawValue) kind=\(describeKind(event.kind)) terminal=\(ctx?.terminalName ?? event.terminalName ?? "-") tty=\(ctx?.tty ?? event.tty ?? "-") pid=\(ctx?.pid.map(String.init) ?? event.pid.map(String.init) ?? "-")"
            )
            event.pending?.resolve(.ask)
            return
        }

        // 0. Respect user's event filters
        guard isEventKindEnabled(event.kind) else {
            DiagnosticLogger.shared.info("Notch drop: disabled-by-filter provider=\(event.provider.rawValue) kind=\(describeKind(event.kind))")
            event.pending?.resolve(.ask)  // hook gets a pass-through decision
            return
        }

        if shouldSuppressInformationalEvent(event) {
            DiagnosticLogger.shared.info("Notch drop: suppress-informational provider=\(event.provider.rawValue) kind=\(describeKind(event.kind))")
            event.pending?.resolve(.ask)
            return
        }

        // 1. Dedup permission requests by toolUseId.
        // Keep the first in-flight request and let later duplicates fall through
        // to the CLI's native behavior. Replacing the visible one with `.deny`
        // is too aggressive: some CLIs emit the same approval more than once,
        // and denying the older socket can reject the real prompt before the
        // user has a chance to click Allow.
        if case .permissionRequest(_, _, let toolUseId) = event.kind, !toolUseId.isEmpty {
            if let existingId = pendingByToolUseId[toolUseId] {
                DiagnosticLogger.shared.warning("Notch dedup: same toolUseId=\(toolUseId.prefix(8)) keeping existing=\(existingId.uuidString.prefix(8))")
                event.pending?.resolve(.ask)
                return
            }
            pendingByToolUseId[toolUseId] = event.id
        }

        // 2. Insert by priority (lower priority.number = higher importance)
        let insertIdx = queue.firstIndex { $0.kind.priority > event.kind.priority } ?? queue.endIndex
        queue.insert(event, at: insertIdx)
        DiagnosticLogger.shared.info("Notch queued at index=\(insertIdx) queueCount=\(queue.count) currentEvent=\(currentEvent.map { String($0.id.uuidString.prefix(8)) } ?? "nil")")

        // 3. Schedule response timeout if applicable
        if event.pending != nil { scheduleTimeout(for: event) }

        // 4. Play sound for high-priority events
        if case .permissionRequest = event.kind {
            NotchSoundPlayer.playPermissionSound()
        }

        advance()
    }

    private func isEventKindEnabled(_ kind: AttentionKind) -> Bool {
        let d = UserDefaults.standard
        // Per-provider master switches are enforced at the bridge layer; events
        // that reach this point already passed that check. Only filter by event
        // category here.
        switch kind {
        case .permissionRequest:
            return d.object(forKey: "notch.events.permission") == nil || d.bool(forKey: "notch.events.permission")
        case .waitingInput:
            return d.object(forKey: "notch.events.waitingInput") == nil || d.bool(forKey: "notch.events.waitingInput")
        case .taskDone:
            return d.object(forKey: "notch.events.taskDone") == nil || d.bool(forKey: "notch.events.taskDone")
        case .taskFailed:
            return d.object(forKey: "notch.events.taskFailed") == nil || d.bool(forKey: "notch.events.taskFailed")
        case .sessionStart:
            return d.bool(forKey: "notch.events.sessionStart") // default off (informational)
        case .activityPulse, .sessionEnd:
            return true
        }
    }

    private func scheduleAutoDismiss(for event: AttentionEvent, after seconds: TimeInterval) {
        guard timeoutTimers[event.id] == nil else { return }
        if currentEvent?.id == event.id {
            currentAutoDismissDeadline = Date().addingTimeInterval(seconds)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.dismiss(id: event.id) }
        timer.resume()
        timeoutTimers[event.id] = timer
    }

    func decide(id: UUID, decision: Decision) {
        DiagnosticLogger.shared.info("Notch decide id=\(id.uuidString.prefix(8)) decision=\(decision.rawValue) current=\(currentEvent.map { String($0.id.uuidString.prefix(8)) } ?? "nil") queueCount=\(queue.count)")
        if currentEvent?.id == id {
            noteDismissed(currentEvent)
            currentEvent?.pending?.resolve(decision)
            clearTimer(id)
            currentEvent = nil
            advance()
        } else if let idx = queue.firstIndex(where: { $0.id == id }) {
            noteDismissed(queue[idx])
            queue[idx].pending?.resolve(decision)
            clearTimer(id)
            queue.remove(at: idx)
            updateCount()
        }
    }

    func dismiss(id: UUID) {
        decide(id: id, decision: .ask)
    }

    /// Drop the currently-shown event and the queued ones that match the given
    /// provider. Pending hook responses are resolved with `.ask` so the CLI
    /// falls through to its native flow. Called when the user disables a
    /// provider's notch switch while events are active.
    func purgeProvider(_ provider: ProviderKind) {
        let queueRemoved = queue.filter { $0.provider == provider }
        queue.removeAll { $0.provider == provider }
        for event in queueRemoved {
            event.pending?.resolve(.ask)
            timeoutTimers[event.id]?.cancel()
            timeoutTimers.removeValue(forKey: event.id)
            if let toolUseId = event.toolUseId {
                pendingByToolUseId.removeValue(forKey: toolUseId)
            }
        }
        if let current = currentEvent, current.provider == provider {
            decide(id: current.id, decision: .ask)
        }
        updateCount()
    }

    /// Pause the auto-dismiss timer for the currently shown event. Called when
    /// the user hovers the notch so they have time to read rich content. Only
    /// applies to events with `autoDismissAfter` set (taskDone / sessionStart);
    /// permission-request timeouts are left alone.
    func pauseAutoDismissForHover() {
        guard let current = currentEvent,
              current.kind.autoDismissAfter != nil else { return }
        timeoutTimers[current.id]?.cancel()
        timeoutTimers.removeValue(forKey: current.id)
        currentAutoDismissDeadline = nil
    }

    /// Re-schedule a fresh auto-dismiss timer when the user stops hovering.
    /// Uses the full original duration so a brief glance doesn't cost the user
    /// their remaining reading time.
    func resumeAutoDismissAfterHover() {
        guard let current = currentEvent,
              let after = current.kind.autoDismissAfter,
              timeoutTimers[current.id] == nil else { return }
        scheduleAutoDismiss(for: current, after: after)
    }

    /// Record an "always allow" rule for (session, tool) and resolve as `.allow`.
    /// Subsequent PermissionRequests matching the rule will be auto-approved without
    /// popping a notch. Rules are cleared when the session ends.
    func allowAlways(id: UUID) {
        let target: AttentionEvent?
        if currentEvent?.id == id {
            target = currentEvent
        } else {
            target = queue.first { $0.id == id }
        }
        if let target,
           case .permissionRequest(let tool, _, _) = target.kind,
           let key = autoAllowKey(provider: target.provider, sessionId: target.sessionId, toolName: tool) {
            autoAllowRules.insert(key)
        }
        decide(id: id, decision: .allow)
    }

    private func autoAllowKey(provider: ProviderKind, sessionId: String, toolName: String?) -> String? {
        guard !sessionId.isEmpty, let toolName, !toolName.isEmpty else { return nil }
        return "\(provider.rawValue):\(sessionId):\(toolName)"
    }

    private func clearAutoAllowRules(provider: ProviderKind, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let prefix = "\(provider.rawValue):\(sessionId):"
        autoAllowRules = autoAllowRules.filter { !$0.hasPrefix(prefix) }
    }

    // Default-on. Users can flip it off in Settings to force every event to
    // surface, useful for debugging when the notch window is hidden but the
    // user can't tell whether it ever fired.
    private func isFocusSilenceEnabled() -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "notch.focusSilence.enabled") == nil
            || d.bool(forKey: "notch.focusSilence.enabled")
    }

    private func isSessionFocused(for event: AttentionEvent) -> Bool {
        let focusContext = activeSessionsTracker?.focusContext(for: event)
        return TerminalFocusCoordinator.isSessionFocused(
            pid: focusContext?.pid ?? event.pid,
            tty: focusContext?.tty ?? event.tty,
            terminalName: focusContext?.terminalName ?? event.terminalName,
            stableTerminalID: focusContext?.terminalStableID ?? event.terminalStableID
        )
    }

    private func describeKind(_ kind: AttentionKind) -> String {
        switch kind {
        case .permissionRequest(let tool, _, let tid): return "permission(\(tool),tid=\(tid.prefix(8)))"
        case .waitingInput:      return "waitingInput"
        case .taskDone:          return "taskDone"
        case .taskFailed:        return "taskFailed"
        case .sessionStart:      return "sessionStart"
        case .activityPulse:     return "activityPulse"
        case .sessionEnd:        return "sessionEnd"
        }
    }

    private func advance() {
        guard currentEvent == nil, !queue.isEmpty else { updateCount(); return }
        currentEvent = queue.removeFirst()
        currentAutoDismissDeadline = nil
        if let currentEvent, let after = currentEvent.kind.autoDismissAfter {
            scheduleAutoDismiss(for: currentEvent, after: after)
        }
        updateCount()
    }

    private func updateCount() { queuedCount = queue.count }

    private func removeDuplicateEvent(_ id: UUID, resolution: Decision) {
        if currentEvent?.id == id {
            noteDismissed(currentEvent)
            currentEvent?.pending?.resolve(resolution)
            clearTimer(id)
            currentEvent = nil
            currentAutoDismissDeadline = nil
        } else if let idx = queue.firstIndex(where: { $0.id == id }) {
            noteDismissed(queue[idx])
            queue[idx].pending?.resolve(resolution)
            clearTimer(id)
            queue.remove(at: idx)
        }
    }

    private func scheduleTimeout(for event: AttentionEvent) {
        guard let pending = event.pending else { return }
        let delay = max(0.1, pending.timeoutAt.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.handleTimeout(id: event.id) }
        timer.resume()
        timeoutTimers[event.id] = timer
    }

    private func handleTimeout(id: UUID) {
        clearTimer(id)
        decide(id: id, decision: .ask)
    }

    private func clearTimer(_ id: UUID) {
        if currentEvent?.id == id {
            currentAutoDismissDeadline = nil
        }
        timeoutTimers.removeValue(forKey: id)?.cancel()
    }

    private func shouldSuppressInformationalEvent(_ event: AttentionEvent) -> Bool {
        guard let key = informationalSessionKey(for: event) else { return false }

        switch event.kind {
        case .waitingInput:
            if displayedWaitingSessionKeys.contains(key)
                || currentEvent.map({ informationalSessionKey(for: $0) == key && $0.kind.isWaitingInput }) == true
                || queue.contains(where: { informationalSessionKey(for: $0) == key && $0.kind.isWaitingInput }) {
                return true
            }
            displayedWaitingSessionKeys.insert(key)
            return false
        case .taskDone, .sessionStart, .taskFailed:
            let now = Date()
            if let last = lastInformationalAtBySession[key],
               now.timeIntervalSince(last) < 30 {
                return true
            }
            lastInformationalAtBySession[key] = now
            return false
        case .permissionRequest, .activityPulse, .sessionEnd:
            return false
        }
    }

    private func noteDismissed(_ event: AttentionEvent?) {
        guard let event else { return }
        if case .permissionRequest(_, _, let toolUseId) = event.kind, !toolUseId.isEmpty {
            pendingByToolUseId.removeValue(forKey: toolUseId)
        }
        guard let key = informationalSessionKey(for: event) else { return }
        if event.kind.isWaitingInput {
            displayedWaitingSessionKeys.remove(key)
        }
    }

    private func clearWaitingInput(for event: AttentionEvent) {
        guard let key = informationalSessionKey(for: event) else { return }
        displayedWaitingSessionKeys.remove(key)

        if currentEvent.map({ informationalSessionKey(for: $0) == key && $0.kind.isWaitingInput }) == true {
            currentEvent?.pending?.resolve(.ask)
            if let id = currentEvent?.id {
                clearTimer(id)
            }
            currentEvent = nil
            currentAutoDismissDeadline = nil
        }

        queue.removeAll { queued in
            guard informationalSessionKey(for: queued) == key, queued.kind.isWaitingInput else {
                return false
            }
            queued.pending?.resolve(.ask)
            clearTimer(queued.id)
            return true
        }

        advance()
    }

    private func informationalSessionKey(for event: AttentionEvent) -> String? {
        guard !event.sessionId.isEmpty else { return nil }
        return "\(event.provider.rawValue):\(event.sessionId)"
    }

    private func enrichPermissionRequest(_ event: AttentionEvent) -> AttentionEvent {
        guard case .permissionRequest = event.kind,
              (event.toolUseId ?? "").isEmpty,
              let resolvedToolUseId = activeSessionsTracker?.approvalToolUseId(
                provider: event.provider,
                sessionId: event.sessionId
              ) else {
            return event
        }

        let enriched = event.withResolvedPermissionToolUseId(resolvedToolUseId)
        if enriched.toolUseId != event.toolUseId {
            DiagnosticLogger.shared.info(
                "Notch permission enriched session=\(event.sessionId) tool=\(event.toolName ?? "-") toolUseId=\(resolvedToolUseId)"
            )
        }
        return enriched
    }

    private func clearResolvedPermissionRequests(for event: AttentionEvent) {
        guard event.rawEventName == "PostToolUse"
            || event.rawEventName == "PostToolUseFailure"
            || event.rawEventName == "Stop"
            || event.rawEventName == "StopFailure"
            || event.rawEventName == "SessionEnd" else {
            return
        }

        if let current = currentEvent, shouldClearPermission(current, becauseOf: event) {
            DiagnosticLogger.shared.info(
                "Notch stale permission cleared current session=\(current.sessionId) trigger=\(event.rawEventName) toolUseId=\(event.toolUseId ?? "-")"
            )
            removeDuplicateEvent(current.id, resolution: .ask)
        }

        let staleIDs = queue
            .filter { shouldClearPermission($0, becauseOf: event) }
            .map(\.id)
        for id in staleIDs {
            DiagnosticLogger.shared.info(
                "Notch stale permission cleared queued trigger=\(event.rawEventName) toolUseId=\(event.toolUseId ?? "-")"
            )
            removeDuplicateEvent(id, resolution: .ask)
        }
    }

    private func shouldClearPermission(_ candidate: AttentionEvent, becauseOf trigger: AttentionEvent) -> Bool {
        guard case .permissionRequest(let permissionTool, _, let permissionToolUseId) = candidate.kind else {
            return false
        }
        guard candidate.provider == trigger.provider,
              candidate.sessionId == trigger.sessionId else {
            return false
        }

        if trigger.rawEventName == "Stop" || trigger.rawEventName == "StopFailure" || trigger.rawEventName == "SessionEnd" {
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

private extension AttentionKind {
    var isWaitingInput: Bool {
        if case .waitingInput = self { return true }
        return false
    }

    var clearsWaitingInput: Bool {
        switch self {
        case .activityPulse, .permissionRequest, .sessionEnd:
            return true
        case .taskFailed, .waitingInput, .taskDone, .sessionStart:
            return false
        }
    }
}
