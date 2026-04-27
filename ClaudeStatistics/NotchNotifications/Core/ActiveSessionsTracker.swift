import Combine
import ClaudeStatisticsKit
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
    private let persistor = RuntimeStatePersistor()
    // Sessions evicted by same-tab displacement stay hidden for one activeWindow
    // so stale persisted runtime cannot briefly reappear after a tab switches CLIs.
    private var displacedSessionIds: [String: Date] = [:]
    // Cache for `terminal_name` inferred from a hook's pid via ProcessTreeWalker.
    // Filled when a hook arrives without `terminal_name` (e.g. Codex.app embeds
    // codex-cli with no PTY → no TERM_PROGRAM → no alias to filter on). Walking
    // the process chain runs `/bin/ps` so it must stay off the main path; we
    // resolve once per pid asynchronously and replay through `refresh()`.
    private var inferredTerminalNameByPid: [pid_t: String] = [:]
    private var pidInferenceInFlight: Set<pid_t> = []

    /// Filter chain run against every incoming hook and persisted
    /// runtime. Built at startup from host-internal filters plus every
    /// `ProviderPlugin.makeSessionFilters()`. Logical-AND: row is shown
    /// only when every filter returns `true`.
    var sessionFilters: [any SessionEventFilter] = []
    /// Session ids any filter has dropped. Persisted in memory only —
    /// rebuilt on restart by re-running the chain on persisted runtimes.
    private var droppedSessionIds: Set<String> = []

    init() {
        self.runtimeByKey = TerminalIdentityResolver.sanitizedGhosttyCollisions(
            (persistor.load() ?? [:])
                .mapValues { TerminalIdentityResolver.sanitized($0) }
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
        let filtered = TerminalIdentityResolver.sanitizedGhosttyCollisions(
            runtimeByKey
                .filter { shouldKeep(runtime: $0.value, cutoff: cutoff, now: now) }
                .mapValues { TerminalIdentityResolver.sanitized($0) }
        )

        let dropChanged = filtered.count != runtimeByKey.count || Set(filtered.keys) != Set(runtimeByKey.keys)
        runtimeByKey = filtered

        // Sweep zombie activeTools entries — Claude Code exiting via a closed
        // tab / Ctrl+C / crash skips SessionEnd, leaving the detailed row
        // ticking "4m49s, 5m12s, …" on a tool whose PostToolUse will never
        // arrive. Drop entries older than the stale window so the row is
        // truthful instead of misleading.
        let staleCutoff = now.addingTimeInterval(-ActiveSession.staleActiveToolWindow)
        var toolSweepChanged = false
        for (key, runtime) in runtimeByKey {
            guard !runtime.activeTools.isEmpty else { continue }
            let pruned = runtime.activeTools.filter { $0.value.startedAt >= staleCutoff }
            guard pruned.count != runtime.activeTools.count else { continue }
            var updated = runtime
            updated.activeTools = pruned
            runtimeByKey[key] = updated
            toolSweepChanged = true
        }

        guard dropChanged || toolSweepChanged else { return }
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

    /// Rebuild a lightweight runtime shell from already-scanned sessions when a
    /// provider's notch switch turns back on — and, crucially, on app launch.
    /// Fills in prompt / progress note / preview from stats so the first UI
    /// render has real text instead of flashing the fallback triptych ("No
    /// prompt yet / Idle / Waiting for input") for the 1–3 s it otherwise
    /// takes `syncTranscriptSignals` to do its first pass.
    func restoreRuntime(
        for provider: ProviderKind,
        sessions sourceSessions: [Session],
        quickStats: [String: SessionQuickStats] = [:],
        parsedStats: [String: SessionStats] = [:]
    ) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-activeWindow)
        let providerId = provider.rawValue
        let recentSessions = sourceSessions
            .filter { $0.provider == providerId && $0.lastModified > cutoff }
            .sorted { $0.lastModified > $1.lastModified }

        guard !recentSessions.isEmpty else { return }

        var didRestore = false
        var restoredProjectKeys: Set<String> = []
        for session in recentSessions {
            let projectKey = normalizedRestoreProjectKey(for: session)
            if restoredProjectKeys.contains(projectKey) {
                continue
            }
            let runtimeSessionID = Self.runtimeSessionID(for: session)
            let key = Self.key(provider: provider, sessionId: runtimeSessionID)
            let signals = RuntimeSessionEventApplier.signals(from: quickStats[session.id], stats: parsedStats[session.id])

            if var existing = runtimeByKey[key] {
                // Already present (persisted JSON path). Backfill any nil
                // text fields from stats so the UI has content immediately.
                let before = existing
                RuntimeSessionEventApplier.merge(runtime: &existing, signals: signals)
                if existing != before {
                    runtimeByKey[key] = TerminalIdentityResolver.sanitized(existing)
                    didRestore = true
                }
                restoredProjectKeys.insert(projectKey)
                continue
            }

            var fresh = RuntimeSession(
                provider: provider,
                sessionId: runtimeSessionID,
                projectPath: session.cwd?.nilIfEmpty ?? session.projectPath.nilIfEmpty,
                currentActivity: nil,
                latestProgressNote: nil,
                latestProgressNoteAt: nil,
                latestPreview: nil,
                currentOperation: nil,
                tty: nil,
                pid: nil,
                terminalName: nil,
                terminalSocket: nil,
                terminalWindowID: nil,
                terminalTabID: nil,
                terminalStableID: nil,
                lastActivityAt: session.lastModified,
                status: .running,
                currentToolDetail: nil
            )
            RuntimeSessionEventApplier.merge(runtime: &fresh, signals: signals)
            runtimeByKey[key] = TerminalIdentityResolver.sanitized(fresh)
            DiagnosticLogger.shared.verbose(
                "Active restore provider=\(provider.rawValue) session=\(runtimeSessionID) sourceID=\(session.id) project=\(session.cwd?.nilIfEmpty ?? session.projectPath.nilIfEmpty ?? "-") lastModified=\(session.lastModified.timeIntervalSince1970) signals=\(signals.count)"
            )
            restoredProjectKeys.insert(projectKey)
            didRestore = true
        }

        guard didRestore else { return }
        persistRuntime()
        refresh()
    }

    func record(event: AttentionEvent) {
        guard !event.sessionId.isEmpty else { return }

        // Run the filter chain. Any filter returning false drops the
        // session — pre-built runtime from earlier hooks (SessionStart
        // hits before UserPromptSubmit, so synthetic prompts are caught
        // on the second event) is purged so the row vanishes.
        let filterCtx = filterContext(forEvent: event)
        if !sessionFilters.allSatisfy({ $0.shouldDisplay(filterCtx) }) {
            droppedSessionIds.insert(event.sessionId)
        }
        if droppedSessionIds.contains(event.sessionId) {
            let key = Self.key(provider: event.provider, sessionId: event.sessionId)
            if runtimeByKey.removeValue(forKey: key) != nil {
                persistRuntime()
                refresh()
            }
            return
        }

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
            currentActivitySemanticKey: ToolActivityFormatter.liveSemanticKey(
                rawEventName: event.rawEventName,
                toolName: event.toolName,
                input: event.toolInput,
                toolUseId: event.toolUseId
            ),
            latestProgressNote: event.liveProgressNote,
            latestProgressNoteAt: event.liveProgressNote == nil ? nil : (event.liveProgressNoteAt ?? event.receivedAt),
            latestPreview: event.livePreview,
            currentOperation: ToolActivityFormatter.currentOperation(
                rawEventName: event.rawEventName,
                toolName: event.toolName,
                input: event.toolInput,
                provider: event.provider,
                receivedAt: event.receivedAt,
                toolUseId: event.toolUseId
            ),
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
            runtime.currentActivitySemanticKey = nil
        } else if event.rawEventName == "PostToolUse"
                    || event.rawEventName == "PostToolUseFailure" {
            // Clear on tool completion so MIDDLE doesn't keep echoing the
            // just-finished "Read foo.swift" — the detail section already
            // shows the entry as an afterglow ("finished 4s ago"), and this
            // way MIDDLE falls through to the static status fallback instead
            // of duplicating the same file in both rows. The old rationale
            // (avoid flicker to "Thinking…" between chained tool calls) is
            // now better addressed by the detail section carrying the
            // recent-tool context; the next PreToolUse fires within a frame
            // in the chained case anyway, so no user-visible flicker.
            runtime.currentActivity = nil
            runtime.currentActivitySemanticKey = nil
        } else if let liveActivity = event.liveActivitySummary {
            runtime.currentActivity = liveActivity
            runtime.currentActivitySemanticKey = ToolActivityFormatter.liveSemanticKey(
                rawEventName: event.rawEventName,
                toolName: event.toolName,
                input: event.toolInput,
                toolUseId: event.toolUseId
            )
        }
        if let formatted = RuntimeSessionEventApplier.formatToolOutput(for: event) {
            runtime.latestToolOutput = formatted.text
            runtime.latestToolOutputSummary = formatted
            runtime.latestToolOutputTool = event.toolName ?? runtime.currentToolName
            runtime.latestToolOutputAt = event.receivedAt
        }
        if let prompt = event.livePrompt {
            runtime.latestPrompt = prompt
            runtime.latestPromptAt = event.receivedAt
        }
        if let progressNote = event.liveProgressNote {
            // Prefer the transcript-native timestamp (the moment Claude wrote
            // the text) over receivedAt (when the hook fired, often the same
            // Date as the ensuing PreToolUse's action.startedAt). Without this
            // distinction the triptych UI can't tell which came first.
            let incomingAt = event.liveProgressNoteAt ?? event.receivedAt
            // Only overwrite when the incoming note is at least as fresh as
            // the one we already have. Without this guard, a stale hook
            // snapshot (e.g. tail-scan hit an earlier assistant entry
            // because the newest one wasn't flushed yet, or was beyond the
            // 256 KB window) would repeatedly clobber the fresher text the
            // SessionScanner just merged via syncTranscriptSignals.
            let shouldOverwrite: Bool = {
                guard let existingAt = runtime.latestProgressNoteAt else { return true }
                return incomingAt >= existingAt
            }()
            if shouldOverwrite {
                runtime.latestProgressNote = progressNote
                runtime.latestProgressNoteAt = incomingAt
            }
        }
        RuntimeSessionEventApplier.apply(event: event, to: &runtime)
        let hadActiveOperation = runtime.currentToolName != nil
            || runtime.currentToolStartedAt != nil
            || runtime.currentOperation?.keepsSessionRunning == true
        runtime.status = RuntimeSessionEventApplier.deriveStatus(
            for: event.kind,
            rawName: event.rawEventName,
            previous: runtime.status,
            hadActiveOperation: hadActiveOperation
        )
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
        // Fallback for hosts that fire hooks without TERM_PROGRAM (e.g.
        // Codex.app embeds codex-cli with no PTY). When the hook's pid maps
        // to a registered terminal/plugin via the parent process chain, keep
        // the row alive instead of letting the focus filter drop it.
        if (runtime.terminalName?.nilIfEmpty == nil), let pid = runtime.pid {
            if let cached = inferredTerminalNameByPid[pid] {
                runtime.terminalName = cached
            } else {
                kickOffTerminalNameInference(forPid: pid)
            }
        }
        runtime.terminalSocket = event.terminalSocket?.nilIfEmpty ?? runtime.terminalSocket
        if shouldAcceptTerminalIdentity {
            runtime.terminalWindowID = event.terminalWindowID?.nilIfEmpty ?? runtime.terminalWindowID
            runtime.terminalTabID = event.terminalTabID?.nilIfEmpty ?? runtime.terminalTabID
            runtime.terminalStableID = event.terminalStableID?.nilIfEmpty ?? runtime.terminalStableID
        }
        runtime.lastActivityAt = max(runtime.lastActivityAt, event.receivedAt)
        runtimeByKey[key] = TerminalIdentityResolver.sanitized(runtime)
        persistRuntime()

        refresh()

        // Some TUIs (e.g. Codex) exit shortly after the final Stop event;
        // those providers declare `postStopExitGrace` and we run a fast
        // pid-liveness check after the configured grace window so the
        // session disappears immediately on clean exit instead of
        // waiting for the next 2 s liveness poll.
        if let grace = event.provider.descriptor.postStopExitGrace,
           case .taskDone = event.kind,
           let pid = event.pid {
            schedulePostStopExitCheck(key: key, pid: pid, grace: grace)
        }

    }

    func syncTranscriptSignals(
        provider: ProviderKind,
        sessions sourceSessions: [Session],
        quickStats: [String: SessionQuickStats],
        parsedStats: [String: SessionStats]
    ) {
        guard !sourceSessions.isEmpty else { return }

        let sessionsByRuntimeID = Dictionary(uniqueKeysWithValues: sourceSessions.map {
            (Self.runtimeSessionID(for: $0), $0)
        })

        var didChange = false
        var matchedRuntimeCount = 0
        var signalCount = 0
        var progressNoteCount = 0
        for (key, var runtime) in runtimeByKey where runtime.provider == provider {
            guard let session = sessionsByRuntimeID[runtime.sessionId] else { continue }
            matchedRuntimeCount += 1
            let quick = quickStats[session.id]
            let stats = parsedStats[session.id]
            let signals = RuntimeSessionEventApplier.signals(from: quick, stats: stats)
            guard !signals.isEmpty else { continue }
            signalCount += signals.count
            progressNoteCount += signals.filter { $0.kind == .progressNote }.count

            let before = runtime
            runtime.projectPath = runtime.projectPath ?? session.cwd?.nilIfEmpty ?? session.projectPath.nilIfEmpty
            RuntimeSessionEventApplier.merge(runtime: &runtime, signals: signals)

            if runtime != before {
                runtimeByKey[key] = TerminalIdentityResolver.sanitized(runtime)
                didChange = true
            }
        }
        DiagnosticLogger.shared.verbose(
            "Active transcript sync provider=\(provider.rawValue) runtimes=\(runtimeByKey.values.filter { $0.provider == provider }.count) matched=\(matchedRuntimeCount) signals=\(signalCount) progressNotes=\(progressNoteCount) changed=\(didChange)"
        )

        guard didChange else { return }
        persistRuntime()
        refresh()
    }

    private func displacePriorSessionsInSameTab(excludingKey newKey: String, event: AttentionEvent) {
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: newKey,
            in: runtimeByKey
        )
        guard !displaced.isEmpty else { return }
        let now = Date()
        for entry in displaced {
            runtimeByKey.removeValue(forKey: entry.key)
            displacedSessionIds[entry.sessionId] = now
        }
    }

    private func shouldAcceptTerminalIdentity(
        forKey key: String,
        terminalName: String?,
        incomingTTY: String?,
        incomingTabID: String?,
        incomingStableID: String?
    ) -> Bool {
        TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: key,
            terminalName: terminalName,
            incomingTTY: incomingTTY,
            incomingTabID: incomingTabID,
            incomingStableID: incomingStableID,
            in: runtimeByKey
        )
    }

    private func filterContext(forEvent event: AttentionEvent) -> SessionFilterContext {
        SessionFilterContext(
            providerId: event.provider.rawValue,
            sessionId: event.sessionId,
            prompt: event.livePrompt,
            tty: event.tty,
            pid: event.pid,
            terminalName: event.terminalName,
            projectPath: event.projectPath
        )
    }

    private func filterContext(forRuntime runtime: RuntimeSession) -> SessionFilterContext {
        SessionFilterContext(
            providerId: runtime.provider.rawValue,
            sessionId: runtime.sessionId,
            prompt: runtime.latestPrompt,
            tty: runtime.tty,
            pid: runtime.pid,
            terminalName: runtime.terminalName,
            projectPath: runtime.projectPath
        )
    }

    private func kickOffTerminalNameInference(forPid pid: pid_t) {
        guard !pidInferenceInFlight.contains(pid) else { return }
        pidInferenceInFlight.insert(pid)
        Task.detached(priority: .background) { [weak self] in
            let proc = ProcessTreeWalker.findTerminalProcessSynchronously(startingAt: pid)
            await MainActor.run {
                guard let self else { return }
                self.pidInferenceInFlight.remove(pid)
                guard let bundleId = proc?.bundleId,
                      let alias = TerminalRegistry.primaryTerminalNameAlias(forBundleId: bundleId) else {
                    return
                }
                self.inferredTerminalNameByPid[pid] = alias
                self.backfillTerminalName(forPid: pid, alias: alias)
                self.refresh()
            }
        }
    }

    private func backfillTerminalName(forPid pid: pid_t, alias: String) {
        var changed = false
        for (key, runtime) in runtimeByKey
            where runtime.pid == pid && (runtime.terminalName?.nilIfEmpty == nil) {
            var updated = runtime
            updated.terminalName = alias
            runtimeByKey[key] = TerminalIdentityResolver.sanitized(updated)
            changed = true
        }
        if changed {
            persistRuntime()
        }
    }

    private func schedulePostStopExitCheck(key: String, pid: Int32, grace: TimeInterval) {
        let nanos = UInt64(max(0, grace) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let runtime = self.runtimeByKey[key],
                      runtime.provider.descriptor.postStopExitGrace != nil,
                      runtime.pid == pid,
                      !LivenessChecker.isProcessAlive(pid) else { return }
                self.runtimeByKey.removeValue(forKey: key)
                self.persistRuntime()
                self.refresh()
            }
        }
    }

    func refresh() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-activeWindow)
        // Re-evaluate persisted runtimes against the filter chain. Catches
        // rows persisted before a filter existed (e.g. an upgraded plugin
        // adds a new synthetic-prompt rule) so a restart cleans them up
        // rather than indefinitely carrying stale rows.
        if !sessionFilters.isEmpty {
            for (key, runtime) in runtimeByKey {
                let ctx = filterContext(forRuntime: runtime)
                if !sessionFilters.allSatisfy({ $0.shouldDisplay(ctx) }) {
                    droppedSessionIds.insert(runtime.sessionId)
                    runtimeByKey.removeValue(forKey: key)
                }
            }
        }
        runtimeByKey = TerminalIdentityResolver.sanitizedGhosttyCollisions(runtimeByKey
            .filter { shouldKeep(runtime: $0.value, cutoff: cutoff, now: now) }
            .mapValues { TerminalIdentityResolver.sanitized($0) })
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
        return LivenessChecker.shouldKeepSession(
            provider: runtime.provider,
            lastActivityAt: runtime.lastActivityAt,
            pid: runtime.pid,
            tty: runtime.tty,
            terminalSocket: runtime.terminalSocket,
            cutoff: cutoff,
            now: now
        )
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
           let activity = runtime.currentOperation?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !activity.isEmpty {
            return activity
        }
        if let runtime = runtimeByKey[key],
           let activity = runtime.currentActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
           !activity.isEmpty {
            return activity
        }
        if let session = sessions.first(where: { $0.focusKey == key }),
           let activity = session.currentOperation?.text.trimmingCharacters(in: .whitespacesAndNewlines),
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

    func resolveApproval(provider: ProviderKind, sessionId: String, decision: Decision) {
        // Any decision — allow/deny/ask — is the precise end-of-approval signal.
        // `.ask` used to early-return, which left the approval label hanging
        // on screen until the 60s stale timer kicked in; in practice the user
        // had already dismissed the card or the timeout had fired, so we know
        // the request is resolved regardless of which decision we sent back.
        let key = Self.key(provider: provider, sessionId: sessionId)
        guard var runtime = runtimeByKey[key], runtime.approvalStartedAt != nil else { return }

        runtime.approvalToolName = nil
        runtime.approvalToolDetail = nil
        runtime.approvalStartedAt = nil
        runtime.approvalToolUseId = nil

        if decision == .deny {
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            if runtime.currentOperation?.kind == .tool {
                runtime.currentOperation = nil
            }
        }

        let hasLiveWork = runtime.currentToolName != nil
            || runtime.currentToolStartedAt != nil
            || runtime.currentOperation?.keepsSessionRunning == true
            || runtime.backgroundShellCount > 0
            || runtime.activeSubagentCount > 0

        runtime.status = hasLiveWork ? .running : .waiting
        runtime.lastActivityAt = Date()
        runtimeByKey[key] = TerminalIdentityResolver.sanitized(runtime)
        persistRuntime()
        refresh()
    }

    private static func key(provider: ProviderKind, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }

    private func normalizedRestoreProjectKey(for session: Session) -> String {
        let path = session.cwd?.nilIfEmpty ?? session.projectPath.nilIfEmpty
        guard let path else { return "session:\(session.id)" }
        return "path:\((path as NSString).expandingTildeInPath)"
    }

    private func persistRuntime() {
        persistor.scheduleWrite(runtimeByKey)
    }

    private func flushPersistRuntime() {
        persistor.flushWrite(runtimeByKey)
    }

    private static func runtimeSessionID(for session: Session) -> String {
        let kind = ProviderKind(rawValue: session.provider) ?? .claude
        let raw = session.externalID.nilIfEmpty ?? session.id
        return kind.descriptor.canonicalSessionID(raw)
    }

}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
