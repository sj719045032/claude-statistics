import Combine
import Darwin
import Foundation

struct ActiveSessionFocusContext {
    let pid: Int32?
    let tty: String?
    let projectPath: String?
    let terminalName: String?
    let terminalSocket: String?
    let terminalWindowID: String?
    let terminalTabID: String?
    let terminalStableID: String?

    var hasFocusHint: Bool {
        pid != nil
            || terminalStableID != nil
            || terminalTabID != nil
            || terminalWindowID != nil
            || tty != nil
            || !(projectPath ?? "").isEmpty
    }
}

@MainActor
final class ActiveSessionsTracker: ObservableObject {
    @Published private(set) var sessions: [ActiveSession] = []
    @Published private(set) var totalCount: Int = 0

    // Grace window driven by live hook traffic. Within this window a session
    // stays listed even if we can't prove the pid/tty are still alive. Past it,
    // we fall back to a pid+terminal liveness check so idle sessions stay as
    // long as the Claude Code process and terminal tab are still around.
    var activeWindow: TimeInterval = 300

    // Safety cap to avoid pathological growth. The idle peek can now expand
    // into a scrollable list, so we can afford to expose substantially more
    // than the default 3-row preview.
    var maxItems: Int = 100

    private var timer: Timer?
    private var livenessTask: Task<Void, Never>?
    private var runtimeByKey: [String: RuntimeSession] = [:]
    private var pendingPersistTask: DispatchWorkItem?
    private static let persistQueue = DispatchQueue(label: "com.claude-statistics.runtime-persist", qos: .utility)
    // Sessions evicted by same-tab displacement stay hidden for one activeWindow
    // so stale persisted runtime cannot briefly reappear after a tab switches CLIs.
    private var displacedSessionIds: [String: Date] = [:]

    init() {
        self.runtimeByKey = Self.sanitizedGhosttyTerminalCollisions(
            Self.loadPersistedRuntime()
                .mapValues { Self.sanitized($0) }
        )
    }

    func start(interval: TimeInterval = 15) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            await self?.monitorProcessLiveness()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        livenessTask?.cancel()
        livenessTask = nil
        flushPersistRuntime()
    }

    // SessionEnd only fires on clean `/exit` or Ctrl+D. Closed tabs, Ctrl+C,
    // crashes, Ctrl+Z, and Ctrl+Z-then-close all bypass it. Poll pids directly
    // so any provider drops off within ~2s instead of waiting for the 15s
    // refresh. Stopped (Ctrl+Z) processes are treated as gone — user typed
    // Ctrl+Z intending to leave; if they `fg` back, SessionStart reappears.
    private func monitorProcessLiveness() async {
        while !Task.isCancelled {
            pruneInactiveSessions()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func pruneInactiveSessions() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-activeWindow)
        let filtered = Self.sanitizedGhosttyTerminalCollisions(
            runtimeByKey
                .filter { shouldKeep(runtime: $0.value, cutoff: cutoff, now: now) }
                .mapValues { Self.sanitized($0) }
        )

        guard filtered.count != runtimeByKey.count || Set(filtered.keys) != Set(runtimeByKey.keys) else {
            return
        }

        runtimeByKey = filtered
        persistRuntime()
        refresh()
    }

    /// Remove every runtime entry for the given provider. Called when the user
    /// flips that provider's notch switch off so stale cards don't linger.
    func purgeRuntime(for provider: ProviderKind) {
        let keysToRemove = runtimeByKey.compactMap { key, runtime -> String? in
            runtime.provider == provider ? key : nil
        }
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove { runtimeByKey.removeValue(forKey: key) }
        persistRuntime()
        refresh()
    }

    func record(event: AttentionEvent) {
        guard !event.sessionId.isEmpty else { return }

        let key = Self.key(provider: event.provider, sessionId: event.sessionId)
        if event.kind == .sessionEnd {
            runtimeByKey.removeValue(forKey: key)
            persistRuntime()
            refresh()
            return
        }

        // Any provider's SessionStart in a given terminal tab means every
        // prior session in that tab has ended — a single tab can only front
        // one AI CLI at a time. Covers the codex-then-claude case where the
        // dead codex pid gets recycled to the new process and would otherwise
        // look alive to kill(0).
        if case .sessionStart = event.kind {
            displacePriorSessionsInSameTab(excludingKey: key, event: event)
        }

        var runtime = runtimeByKey[key] ?? RuntimeSession(
            provider: event.provider,
            sessionId: event.sessionId,
            projectPath: event.projectPath,
            currentActivity: event.liveActivitySummary,
            latestPreview: event.livePreview,
            tty: event.tty?.nilIfEmpty,
            pid: event.pid,
            terminalName: event.terminalName?.nilIfEmpty,
            terminalSocket: event.terminalSocket?.nilIfEmpty,
            terminalWindowID: event.terminalWindowID?.nilIfEmpty,
            terminalTabID: event.terminalTabID?.nilIfEmpty,
            terminalStableID: event.terminalStableID,
            lastActivityAt: event.receivedAt,
            currentToolDetail: nil
        )

        if runtime.projectPath == nil || runtime.projectPath?.isEmpty == true {
            runtime.projectPath = event.projectPath?.nilIfEmpty
        }
        let hasBackgroundWork = runtime.backgroundShellCount > 0 || runtime.activeSubagentCount > 0
        if event.clearsCurrentActivity && !hasBackgroundWork {
            runtime.currentActivity = nil
        } else if let liveActivity = event.liveActivitySummary {
            runtime.currentActivity = liveActivity
        }
        let hadActiveTool = runtime.currentToolName != nil || runtime.currentToolStartedAt != nil
        runtime.status = Self.deriveStatus(
            for: event.kind,
            rawName: event.rawEventName,
            previous: runtime.status,
            hadActiveTool: hadActiveTool
        )
        if let formatted = Self.formatToolOutput(for: event) {
            runtime.latestToolOutput = formatted
            runtime.latestToolOutputTool = event.toolName ?? runtime.currentToolName
            runtime.latestToolOutputAt = event.receivedAt
        }
        if let prompt = event.livePrompt {
            runtime.latestPrompt = prompt
            runtime.latestPromptAt = event.receivedAt
        }
        Self.updateActiveOperations(runtime: &runtime, event: event)
        if let livePreview = event.livePreview {
            runtime.latestPreview = livePreview
            runtime.latestPreviewAt = event.receivedAt
        }
        let incomingTTY = event.tty?.nilIfEmpty
        let incomingTerminalName = event.terminalName?.nilIfEmpty ?? runtime.terminalName
        let shouldAcceptTerminalIdentity = shouldAcceptTerminalIdentity(
            forKey: key,
            terminalName: incomingTerminalName,
            incomingTTY: incomingTTY,
            incomingTabID: event.terminalTabID?.nilIfEmpty,
            incomingStableID: event.terminalStableID?.nilIfEmpty
        )

        runtime.tty = incomingTTY ?? runtime.tty
        runtime.pid = event.pid ?? runtime.pid
        runtime.terminalName = incomingTerminalName
        runtime.terminalSocket = event.terminalSocket?.nilIfEmpty ?? runtime.terminalSocket
        if shouldAcceptTerminalIdentity {
            runtime.terminalWindowID = event.terminalWindowID?.nilIfEmpty ?? runtime.terminalWindowID
            runtime.terminalTabID = event.terminalTabID?.nilIfEmpty ?? runtime.terminalTabID
            runtime.terminalStableID = event.terminalStableID?.nilIfEmpty ?? runtime.terminalStableID
        }
        runtime.lastActivityAt = max(runtime.lastActivityAt, event.receivedAt)
        runtimeByKey[key] = Self.sanitized(runtime)
        persistRuntime()

        refresh()

        // Codex TUI often exits the process shortly after the final Stop event.
        // Give it a brief grace period and then drop the session if the pid is
        // already gone — this catches the clean-exit case quickly, without
        // waiting for the 2 s liveness poll.
        if event.provider == .codex, case .taskDone = event.kind, let pid = event.pid {
            schedulePostStopExitCheck(key: key, pid: pid)
        }

    }

    private func displacePriorSessionsInSameTab(excludingKey newKey: String, event: AttentionEvent) {
        let tty = event.tty?.nilIfEmpty
        let tabID = event.terminalTabID?.nilIfEmpty
        let stableID = event.terminalStableID?.nilIfEmpty
        let isGhostty = TerminalRegistry.bundleId(forTerminalName: event.terminalName) == "com.mitchellh.ghostty"
        // Need at least one terminal identity to match on, otherwise we'd evict
        // unrelated sessions across different tabs.
        guard tty != nil || tabID != nil || stableID != nil else { return }

        let staleEntries = runtimeByKey.compactMap { key, runtime -> (String, String)? in
            guard key != newKey else { return nil }
            if let tty, runtime.tty == tty { return (key, runtime.sessionId) }
            if let stableID, runtime.terminalStableID == stableID {
                if isGhostty, let eventTTY = tty, let runtimeTTY = runtime.tty, runtimeTTY != eventTTY {
                    return nil
                }
                return (key, runtime.sessionId)
            }
            if !isGhostty, let tabID, runtime.terminalTabID == tabID {
                return (key, runtime.sessionId)
            }
            return nil
        }
        let now = Date()
        for (key, sessionId) in staleEntries {
            runtimeByKey.removeValue(forKey: key)
            displacedSessionIds[sessionId] = now
        }
    }

    private func shouldAcceptTerminalIdentity(
        forKey key: String,
        terminalName: String?,
        incomingTTY: String?,
        incomingTabID: String?,
        incomingStableID: String?
    ) -> Bool {
        guard TerminalRegistry.bundleId(forTerminalName: terminalName) == "com.mitchellh.ghostty" else {
            return true
        }
        guard incomingStableID != nil || incomingTabID != nil else { return true }
        guard let incomingTTY else { return true }

        for (otherKey, runtime) in runtimeByKey where otherKey != key {
            guard let runtimeTTY = runtime.tty, runtimeTTY != incomingTTY else { continue }

            if let incomingStableID,
               runtime.terminalStableID == incomingStableID {
                DiagnosticLogger.shared.warning(
                    "Ignored Ghostty terminal id collision key=\(key) stableID=\(incomingStableID) incomingTTY=\(incomingTTY) existingTTY=\(runtimeTTY)"
                )
                return false
            }

            if incomingStableID == nil,
               let incomingTabID,
               runtime.terminalTabID == incomingTabID {
                DiagnosticLogger.shared.warning(
                    "Ignored Ghostty tab id collision key=\(key) tabID=\(incomingTabID) incomingTTY=\(incomingTTY) existingTTY=\(runtimeTTY)"
                )
                return false
            }
        }

        return true
    }

    private func schedulePostStopExitCheck(key: String, pid: Int32) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let runtime = self.runtimeByKey[key],
                      runtime.provider == .codex,
                      runtime.pid == pid,
                      !Self.isProcessAlive(pid) else { return }
                self.runtimeByKey.removeValue(forKey: key)
                self.persistRuntime()
                self.refresh()
            }
        }
    }

    func refresh() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-activeWindow)
        runtimeByKey = Self.sanitizedGhosttyTerminalCollisions(runtimeByKey
            .filter { shouldKeep(runtime: $0.value, cutoff: cutoff, now: now) }
            .mapValues { Self.sanitized($0) })
        persistRuntime()

        displacedSessionIds = displacedSessionIds.filter { now.timeIntervalSince($0.value) < activeWindow }

        var merged: [String: ActiveSession] = [:]
        for runtime in runtimeByKey.values {
            let key = Self.key(provider: runtime.provider, sessionId: runtime.sessionId)
            guard !displacedSessionIds.keys.contains(runtime.sessionId) else { continue }
            merged[key] = runtime.activeSession
        }

        let fresh = Array(merged.values)
            .sorted {
                if $0.hasFocusHint != $1.hasFocusHint {
                    return $0.hasFocusHint && !$1.hasFocusHint
                }
                return $0.lastActivityAt > $1.lastActivityAt
            }
        totalCount = fresh.count
        sessions = Array(fresh.prefix(maxItems))
    }

    private func shouldKeep(runtime: RuntimeSession, cutoff: Date, now: Date) -> Bool {
        return shouldKeepSessionLike(
            provider: runtime.provider,
            lastActivityAt: runtime.lastActivityAt,
            pid: runtime.pid,
            tty: runtime.tty,
            terminalSocket: runtime.terminalSocket,
            cutoff: cutoff,
            now: now
        )
    }

    private func shouldKeepSessionLike(
        provider: ProviderKind,
        lastActivityAt: Date,
        pid: Int32?,
        tty: String?,
        terminalSocket: String?,
        cutoff: Date,
        now: Date
    ) -> Bool {
        if let pid, pid > 0 {
            if now.timeIntervalSince(lastActivityAt) > 10, !Self.isProcessAlive(pid) {
                return false
            }
            // Ctrl+Z suspends the CLI. The pid stays but the process is frozen —
            // treat it as gone. `fg` will re-add it via SessionStart if needed.
            if Self.isProcessStopped(pid) {
                return false
            }
        }
        if lastActivityAt > cutoff {
            return true
        }
        guard let pid, pid > 0 else { return false }
        guard Self.isProcessAlive(pid) else { return false }
        return Self.isTerminalContextAlive(tty: tty, terminalSocket: terminalSocket)
    }

    func stableProjectPath(
        provider: ProviderKind,
        sessionId: String,
        fallback: String?
    ) -> String? {
        let key = Self.key(provider: provider, sessionId: sessionId)
        if let session = sessions.first(where: { $0.focusKey == key }),
           let path = session.projectPath, !path.isEmpty {
            return path
        }
        if let runtime = runtimeByKey[key],
           let path = runtime.projectPath, !path.isEmpty {
            return path
        }
        return fallback?.nilIfEmpty
    }

    func focusContext(for event: AttentionEvent) -> ActiveSessionFocusContext {
        let key = Self.key(provider: event.provider, sessionId: event.sessionId)
        let runtime = runtimeByKey[key]
        let session = sessions.first(where: { $0.focusKey == key })

        return ActiveSessionFocusContext(
            pid: event.pid ?? runtime?.pid ?? session?.pid,
            tty: event.tty?.nilIfEmpty ?? runtime?.tty ?? session?.tty,
            projectPath: stableProjectPath(
                provider: event.provider,
                sessionId: event.sessionId,
                fallback: event.projectPath
            ),
            terminalName: event.terminalName?.nilIfEmpty ?? runtime?.terminalName ?? session?.terminalName,
            terminalSocket: event.terminalSocket?.nilIfEmpty ?? runtime?.terminalSocket ?? session?.terminalSocket,
            terminalWindowID: event.terminalWindowID?.nilIfEmpty ?? runtime?.terminalWindowID ?? session?.terminalWindowID,
            terminalTabID: event.terminalTabID?.nilIfEmpty ?? runtime?.terminalTabID ?? session?.terminalTabID,
            terminalStableID: event.terminalStableID?.nilIfEmpty ?? runtime?.terminalStableID ?? session?.terminalStableID
        )
    }

    /// Last known tool activity for a session (e.g. "Reading foo.swift…").
    /// Used by cards to show context next to generic titles like "Claude is waiting".
    func lastActivity(provider: ProviderKind, sessionId: String) -> String? {
        let key = Self.key(provider: provider, sessionId: sessionId)
        if let runtime = runtimeByKey[key],
           let activity = runtime.currentActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
           !activity.isEmpty {
            return activity
        }
        if let session = sessions.first(where: { $0.focusKey == key }),
           let activity = session.currentActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
           !activity.isEmpty {
            return activity
        }
        return nil
    }

    /// Latest preview line for a session — the most recent non-generic payload text.
    func lastPreview(provider: ProviderKind, sessionId: String) -> String? {
        let key = Self.key(provider: provider, sessionId: sessionId)
        if let runtime = runtimeByKey[key],
           let preview = runtime.latestPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            return preview
        }
        if let session = sessions.first(where: { $0.focusKey == key }),
           let preview = session.latestPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            return preview
        }
        return nil
    }

    func approvalToolUseId(provider: ProviderKind, sessionId: String) -> String? {
        let key = Self.key(provider: provider, sessionId: sessionId)
        return runtimeByKey[key]?.approvalToolUseId?.nilIfEmpty
            ?? runtimeByKey[key]?.currentToolUseId?.nilIfEmpty
    }

    private static func key(provider: ProviderKind, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }

    private func persistRuntime() {
        // Debounce: hook events fire 5-10x per Claude turn and each one
        // touched off a synchronous JSONEncoder + atomic file write on the
        // MainActor, which made pointer/click interactions stutter during
        // active sessions. Coalesce into one write every 400ms on a
        // background queue.
        let snapshot = runtimeByKey
        pendingPersistTask?.cancel()
        let task = DispatchWorkItem {
            Self.persistRuntime(snapshot)
        }
        pendingPersistTask = task
        Self.persistQueue.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    private func flushPersistRuntime() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        Self.persistRuntime(runtimeByKey)
    }

    private static var persistedRuntimeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Claude Statistics", isDirectory: true)
            .appendingPathComponent("active-sessions-runtime.json")
    }

    private static func loadPersistedRuntime() -> [String: RuntimeSession] {
        let url = persistedRuntimeURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: RuntimeSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func sanitized(_ runtime: RuntimeSession) -> RuntimeSession {
        var copy = runtime
        if let preview = copy.latestPreview, isGenericWaitingPreview(preview) {
            copy.latestPreview = nil
        }
        if let approvalStartedAt = copy.approvalStartedAt,
           Date().timeIntervalSince(approvalStartedAt) >= ActiveSession.approvalStaleInterval {
            copy.approvalToolName = nil
            copy.approvalToolDetail = nil
            copy.approvalStartedAt = nil
            copy.approvalToolUseId = nil
        }
        return copy
    }

    private static func sanitizedGhosttyTerminalCollisions(
        _ runtimes: [String: RuntimeSession]
    ) -> [String: RuntimeSession] {
        var result = runtimes
        let ghosttyEntries = runtimes.compactMap { key, runtime -> (key: String, runtime: RuntimeSession)? in
            guard TerminalRegistry.bundleId(forTerminalName: runtime.terminalName) == "com.mitchellh.ghostty",
                  runtime.terminalStableID?.nilIfEmpty != nil,
                  runtime.tty?.nilIfEmpty != nil else {
                return nil
            }
            return (key, runtime)
        }

        let grouped = Dictionary(grouping: ghosttyEntries) { $0.runtime.terminalStableID ?? "" }
        for (stableID, entries) in grouped where entries.count > 1 {
            let distinctTTYs = Set(entries.compactMap { $0.runtime.tty?.nilIfEmpty })
            guard distinctTTYs.count > 1 else { continue }

            let keepKey = entries
                .max { $0.runtime.lastActivityAt < $1.runtime.lastActivityAt }?
                .key
            for entry in entries where entry.key != keepKey {
                guard var runtime = result[entry.key] else { continue }
                runtime.terminalWindowID = nil
                runtime.terminalTabID = nil
                runtime.terminalStableID = nil
                result[entry.key] = runtime
                DiagnosticLogger.shared.warning(
                    "Cleared ambiguous Ghostty terminal id key=\(entry.key) stableID=\(stableID) tty=\(entry.runtime.tty ?? "-")"
                )
            }
        }

        return result
    }

    /// Update fields tracking what tool is currently active in this session
    /// and how many background shells / subagents are running.
    private static func updateActiveOperations(runtime: inout RuntimeSession, event: AttentionEvent) {
        switch event.rawEventName {
        case "PermissionRequest", "ToolPermission":
            let detail = operationSummary(for: event)
            runtime.currentToolName = event.toolName ?? runtime.currentToolName
            runtime.currentToolDetail = detail ?? runtime.currentToolDetail
            runtime.currentToolStartedAt = runtime.currentToolStartedAt ?? event.receivedAt
            if let toolUseId = event.toolUseId?.nilIfEmpty {
                runtime.currentToolUseId = toolUseId
            }
            runtime.approvalToolName = runtime.currentToolName ?? event.toolName
            runtime.approvalToolDetail = runtime.currentToolDetail ?? detail
            runtime.approvalStartedAt = event.receivedAt
            runtime.approvalToolUseId = event.toolUseId?.nilIfEmpty ?? runtime.currentToolUseId

        case "PreToolUse":
            runtime.currentToolName = event.toolName
            runtime.currentToolDetail = operationSummary(for: event)
            runtime.currentToolStartedAt = event.receivedAt
            runtime.currentToolUseId = event.toolUseId
            // Backgrounded bash is fire-and-forget on Claude Code's side.
            if event.toolName?.lowercased() == "bash", isBackgroundBash(input: event.toolInput) {
                runtime.backgroundShellCount += 1
            }

        case "PostToolUse", "PostToolUseFailure":
            clearApprovalIfFinished(runtime: &runtime, event: event)
            // Clear current-tool only if it matches the toolUseId we recorded —
            // otherwise an out-of-order PostToolUse from a parallel call would
            // wipe the still-running tool's tracking.
            if let id = event.toolUseId, !id.isEmpty, runtime.currentToolUseId == id {
                runtime.currentToolName = nil
                runtime.currentToolDetail = nil
                runtime.currentToolStartedAt = nil
                runtime.currentToolUseId = nil
            }
            // KillShell decrements background count.
            if event.toolName?.lowercased() == "killshell" {
                runtime.backgroundShellCount = max(0, runtime.backgroundShellCount - 1)
            }

        case "SubagentStart":
            runtime.activeSubagentCount += 1

        case "SubagentStop":
            runtime.activeSubagentCount = max(0, runtime.activeSubagentCount - 1)

        case "Stop", "StopFailure":
            // Turn ended — Claude can't be running a tool anymore.
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil

        case "SessionEnd":
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.backgroundShellCount = 0
            runtime.activeSubagentCount = 0

        default:
            break
        }
    }

    private static func operationSummary(for event: AttentionEvent) -> String? {
        guard let tool = event.toolName, let input = event.toolInput else { return nil }
        return ToolActivityFormatter.operationSummary(tool: tool, input: input)
    }

    private static func clearApprovalIfFinished(runtime: inout RuntimeSession, event: AttentionEvent) {
        let eventToolUseId = event.toolUseId?.nilIfEmpty
        let approvalToolUseId = runtime.approvalToolUseId?.nilIfEmpty

        if let eventToolUseId, let approvalToolUseId {
            guard eventToolUseId == approvalToolUseId else { return }
        } else if let approvalTool = runtime.approvalToolName?.lowercased(),
                  let eventTool = event.toolName?.lowercased() {
            guard approvalTool == eventTool else { return }
        } else if runtime.approvalStartedAt == nil {
            return
        }

        runtime.approvalToolName = nil
        runtime.approvalToolDetail = nil
        runtime.approvalStartedAt = nil
        runtime.approvalToolUseId = nil
    }

    /// Extract a short tail snippet from a tool's response. The icon is
    /// rendered separately by the row UI (SF Symbol via `ActiveSession.toolSymbol`)
    /// so we don't add an emoji prefix here anymore.
    /// Returns nil for events without a useful response or for noisy tools.
    private static func formatToolOutput(for event: AttentionEvent) -> String? {
        if event.rawEventName == "SubagentStop", let raw = event.toolResponse {
            guard let snippet = formatSnippet(raw), !isPlaceholderOutput(snippet) else { return nil }
            return snippet
        }
        guard event.rawEventName == "PostToolUse" || event.rawEventName == "PostToolUseFailure" else {
            return nil
        }
        guard let raw = event.toolResponse else { return nil }
        let toolName = (event.toolName ?? "").lowercased()
        switch toolName {
        case "bash", "bashoutput", "task", "agent", "read",
             "write", "edit", "multiedit", "grep", "webfetch",
             "websearch", "web_search":
            guard let snippet = formatSnippet(raw), !isPlaceholderOutput(snippet) else { return nil }
            return snippet
        default:
            // Skip noise: TodoWrite, internal tools, etc.
            return nil
        }
    }

    private static func isBackgroundBash(input: [String: JSONValue]?) -> Bool {
        guard let input, case .bool(let bg) = input["run_in_background"] else { return false }
        return bg
    }

    private static func formatSnippet(_ raw: String) -> String? {
        // Take the LAST non-empty line (most recent stdout for streaming
        // commands), strip ANSI/whitespace, cap length.
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { cleanedToolOutputLine(stripAnsi(String($0))) }
            .filter { !$0.isEmpty && !isUnhelpfulToolMetadataLine($0) }
        guard let tail = lines.last else { return nil }
        return tail.count > 100 ? String(tail.prefix(100)) + "…" : tail
    }

    private static func cleanedToolOutputLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.lowercased().hasPrefix("output:") {
            let stripped = trimmed.dropFirst("Output:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped
        }

        return trimmed
    }

    private static func isUnhelpfulToolMetadataLine(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("process group pgid:")
            || normalized.hasPrefix("background pids:")
    }

    private static func stripAnsi(_ text: String) -> String {
        // Quick & dirty CSI-escape stripper. Avoids pulling in regex for ~3 lines.
        var result = ""
        var iter = text.unicodeScalars.makeIterator()
        while let c = iter.next() {
            if c == "\u{001B}" {
                // ESC — consume optional `[`, then params/intermediate, then a final byte 0x40-0x7E.
                if let next = iter.next(), next == "[" {
                    while let cc = iter.next() {
                        if cc.value >= 0x40 && cc.value <= 0x7E { break }
                    }
                }
                continue
            }
            result.unicodeScalars.append(c)
        }
        return result
    }

    private static func isPlaceholderOutput(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "text"
            || normalized == "json"
            || normalized == "stdout"
            || normalized == "output"
            || normalized == "(empty)"
            || normalized == "---"
            || normalized == "--"
    }

    private static func deriveStatus(
        for kind: AttentionKind,
        rawName: String,
        previous: ActiveSessionStatus,
        hadActiveTool: Bool
    ) -> ActiveSessionStatus {
        switch kind {
        case .waitingInput:
            // idle_prompt can arrive while a tool approval/execution is still
            // active. In that case the tool state is the more truthful row.
            if hadActiveTool {
                return previous == .approval ? .approval : .running
            }
            return .waiting
        case .taskFailed:
            return .failed
        case .taskDone:
            return .done
        case .permissionRequest:
            return .approval
        case .sessionStart:
            return .running
        case .sessionEnd:
            return previous   // caller removes the runtime entry anyway
        case .activityPulse:
            // Any in-progress signal — PreToolUse, UserPromptSubmit, subagent
            // activity, compaction. These are silent-tracking so they never
            // surface a notch, but they DO mean the session is live.
            switch rawName {
            case "PreCompact", "PostCompact":
                return .running
            case "PostToolUse", "PostToolUseFailure", "SubagentStop":
                // Tool activity ended; if we were showing an approval wait,
                // clear that state so the row doesn't keep saying "approval".
                return previous == .idle || previous == .approval ? .running : previous
            default:
                return .running
            }
        }
    }

    private static func isGenericWaitingPreview(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("waiting for your input")
            || normalized.contains("is waiting for your input")
            || normalized == "awaiting your input"
            || normalized == "waiting for input"
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    // Detect Ctrl+Z-suspended processes via libproc. SSTOP=4 comes from
    // <sys/proc.h>; PROC_PIDT_SHORTBSDINFO=13 from <sys/proc_info.h>.
    // Returns false on any lookup failure (don't evict on unknown state).
    private static func isProcessStopped(_ pid: Int32) -> Bool {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        let bytes = proc_pidinfo(pid, 13, 0, &info, size)
        guard bytes > 0 else { return false }
        return info.pbsi_status == 4
    }

    private static func isTerminalContextAlive(tty: String?, terminalSocket: String?) -> Bool {
        let fileManager = FileManager.default
        if let tty, !tty.isEmpty {
            return fileManager.fileExists(atPath: tty)
        }
        if let terminalSocket, !terminalSocket.isEmpty {
            return fileManager.fileExists(atPath: terminalSocket)
        }
        // Be conservative when older runtime records do not have a terminal
        // locator. A live provider pid is stronger evidence than guessing.
        return true
    }

    private static func persistRuntime(_ runtime: [String: RuntimeSession]) {
        let url = persistedRuntimeURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(runtime)
            try data.write(to: url, options: .atomic)
        } catch {
            DiagnosticLogger.shared.warning("Failed to persist active session runtime: \(error.localizedDescription)")
        }
    }
}

private struct RuntimeSession: Codable {
    let provider: ProviderKind
    let sessionId: String
    var projectPath: String?
    var currentActivity: String?
    var latestPrompt: String? = nil
    var latestPromptAt: Date? = nil
    var latestPreview: String?
    var latestPreviewAt: Date? = nil
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

    var activeSession: ActiveSession {
        ActiveSession(
            id: "runtime:\(provider.rawValue):\(sessionId)",
            sessionId: sessionId,
            provider: provider,
            projectName: projectPath ?? sessionId,
            projectPath: projectPath,
            currentActivity: currentActivity,
            latestPrompt: latestPrompt,
            latestPromptAt: latestPromptAt,
            latestPreview: latestPreview,
            latestPreviewAt: latestPreviewAt,
            lastActivityAt: lastActivityAt,
            tty: tty,
            pid: pid,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            terminalStableID: terminalStableID,
            status: status,
            latestToolOutput: latestToolOutput,
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
            activeSubagentCount: activeSubagentCount
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
