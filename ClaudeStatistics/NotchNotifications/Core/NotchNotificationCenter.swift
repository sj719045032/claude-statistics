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
    // Timestamp of the most recent permission request we silenced due to terminal
    // focus. Used to detect parallel-tool batches: if another permission arrives
    // within a short window, we skip silencing and let it pop so the batch
    // becomes visible in the notch queue.
    private var lastFocusSilencedAt: Date?
    private let focusSilenceBatchWindow: TimeInterval = 1.0

    func enqueue(_ event: AttentionEvent) {
        DiagnosticLogger.shared.info(
            "Notch enqueue start kind=\(describeKind(event.kind)) session=\(event.sessionId) toolUseId=\(event.toolUseId ?? "-") currentEvent=\(currentEvent.map { String($0.id.uuidString.prefix(8)) } ?? "nil") queueCount=\(queue.count)"
        )
        activeSessionsTracker?.record(event: event)
        if event.kind.clearsWaitingInput {
            clearWaitingInput(for: event)
        }
        if case .sessionEnd = event.kind {
            clearAutoAllowRules(provider: event.provider, sessionId: event.sessionId)
        }
        if event.kind.isSilentTracking {
            DiagnosticLogger.shared.info("Notch drop: silent-tracking kind")
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

        // Terminal-focus silencing: when the session's tab is already in the
        // foreground the user can handle the prompt in the terminal itself, so
        // a single redundant notch isn't useful. We skip this when:
        //   • the notch is already busy (current/queued events) — more tool
        //     calls belong in the visible queue, not the terminal one-by-one
        //   • another permission was just silenced within a short window —
        //     indicates a parallel-tool batch, so the remaining ones should pop
        if case .permissionRequest = event.kind,
           currentEvent == nil, queue.isEmpty,
           !recentlySilencedBatch(),
           TerminalFocusCoordinator.isSessionFocused(
                pid: event.pid,
                tty: event.tty,
                terminalName: event.terminalName,
                stableTerminalID: event.terminalStableID
           ) {
            DiagnosticLogger.shared.info("Notch drop: permission focus-silenced (first in batch)")
            lastFocusSilencedAt = Date()
            event.pending?.resolve(.ask)
            return
        }

        // For non-permission user-visible events (waitingInput, taskDone,
        // taskFailed, sessionStart), keep the original simple rule: if the
        // tab is focused, skip — no queueing expectation here.
        if case .permissionRequest = event.kind {
            // handled above
        } else if currentEvent == nil, queue.isEmpty,
                  TerminalFocusCoordinator.isSessionFocused(
                     pid: event.pid,
                     tty: event.tty,
                     terminalName: event.terminalName,
                     stableTerminalID: event.terminalStableID
                  ) {
            event.pending?.resolve(.ask)
            return
        }

        // 0. Respect user's event filters
        guard isEventKindEnabled(event.kind) else {
            event.pending?.resolve(.ask)  // hook gets a pass-through decision
            return
        }

        if shouldSuppressInformationalEvent(event) {
            event.pending?.resolve(.ask)
            return
        }

        // 1. Dedup: if same toolUseId exists (in current or queue), resolve old as .deny.
        // Skip when toolUseId is empty — Claude Code's PermissionRequest payload
        // doesn't include one, and blanks would collide across unrelated events,
        // silently denying the one already visible.
        if case .permissionRequest(_, _, let toolUseId) = event.kind, !toolUseId.isEmpty {
            if let existingId = pendingByToolUseId[toolUseId] {
                DiagnosticLogger.shared.warning("Notch dedup: same toolUseId=\(toolUseId.prefix(8)) replacing existing=\(existingId.uuidString.prefix(8))")
                removeDuplicateEvent(existingId, resolution: .deny)
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

    private func recentlySilencedBatch() -> Bool {
        guard let last = lastFocusSilencedAt else { return false }
        return Date().timeIntervalSince(last) < focusSilenceBatchWindow
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
        guard let event, let key = informationalSessionKey(for: event) else { return }
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
