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
    // Pids whose terminal-name inference came back empty (no host
    // terminal found — genuinely terminal-less cloud / ssh / SDK
    // sessions). Stops `grantInferenceGrace` from re-extending the
    // grace pass forever; cleared if a later attempt succeeds.
    private var inferenceFailedPids: Set<pid_t> = []
    // pid → foreground (tab-owning) `claude` pid, learned from daemon
    // topology recovery. A bg-pty fork child maps to its parent's pid;
    // `refresh` groups by this to collapse same-tab sessions onto one row.
    private var inferredHostPidByPid: [pid_t: pid_t] = [:]
    // De-dupes the per-refresh tab-collapse diagnostic so it logs only
    // when the collapsed set changes (refresh runs on a tight timer).
    private var lastCollapseSignature = ""

    // `mergeLatestTaskIfAvailable` (TodoWrite task list extraction from the
    // Claude transcript) opens, seeks, and reads JSONL on the main thread.
    // Instruments traced 396 ms of main-thread block to a single record() +
    // taskScanResult chain when a transcript got large. These three members
    // let us schedule the scan on a dedicated background queue with per-
    // session debounce: short hook bursts collapse to one scan; the result
    // is merged back to runtimeByKey on the main actor and triggers a single
    // SwiftUI refresh.
    private static let taskScanQueue = DispatchQueue(
        label: "com.claude-statistics.task-scan",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var pendingTaskScans: [String: DispatchWorkItem] = [:]
    private let taskScanDebounce: TimeInterval = 0.05

    /// Filter chain run against every incoming hook and persisted
    /// runtime. Built at startup from host-internal filters plus every
    /// `ProviderPlugin.makeSessionFilters()`. Logical-AND: row is shown
    /// only when every filter returns `true`.
    var sessionFilters: [any SessionEventFilter] = []
    /// Session ids any filter has dropped. Persisted in memory only —
    /// rebuilt on restart by re-running the chain on persisted runtimes.
    private var droppedSessionIds: Set<String> = []

    init() {
        self.runtimeByKey = TerminalIdentityResolver.sanitizedTransientSurfaceCollisions(
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
        let filtered = TerminalIdentityResolver.sanitizedTransientSurfaceCollisions(
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
        var restoredKeys: Set<String> = []
        for session in recentSessions {
            let runtimeSessionID = Self.runtimeSessionID(for: session)
            let key = Self.key(provider: provider, sessionId: runtimeSessionID)
            // De-dupe by runtime key (provider:sessionId), not by cwd —
            // multiple concurrent CLIs can share a project directory and
            // each needs its own runtime entry.
            if restoredKeys.contains(key) { continue }
            let signals = RuntimeSessionEventApplier.signals(from: quickStats[session.id], stats: parsedStats[session.id])

            if var existing = runtimeByKey[key] {
                // Already present (persisted JSON path). Backfill any nil
                // text fields from stats so the UI has content immediately.
                let before = existing
                // Snap projectPath to the JSONL-derived launch dir. Hook
                // payloads carry the CLI's *current* cwd, which drifts when
                // the user moves focus mid-session (Claude's transcript shows
                // multiple cwd values across one session); JSONL's first cwd
                // entry is the stable launch dir we want as the row title.
                if let launchDir = session.cwd?.nilIfEmpty {
                    existing.projectPath = launchDir
                }
                RuntimeSessionEventApplier.merge(runtime: &existing, signals: signals)
                mergeLatestTaskIfAvailable(from: session, into: &existing)
                recoverClaudeProcessContextIfNeeded(for: &existing)
                if existing != before {
                    runtimeByKey[key] = TerminalIdentityResolver.sanitized(existing)
                    didRestore = true
                }
                restoredKeys.insert(key)
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
            mergeLatestTaskIfAvailable(from: session, into: &fresh)
            recoverClaudeProcessContextIfNeeded(for: &fresh)
            runtimeByKey[key] = TerminalIdentityResolver.sanitized(fresh)
            DiagnosticLogger.shared.verbose(
                "Active restore provider=\(provider.rawValue) session=\(runtimeSessionID) sourceID=\(session.id) project=\(session.cwd?.nilIfEmpty ?? session.projectPath.nilIfEmpty ?? "-") lastModified=\(session.lastModified.timeIntervalSince1970) signals=\(signals.count)"
            )
            restoredKeys.insert(key)
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
        // on the second event) is purged so the row vanishes. A pass
        // evicts any prior blacklist entry: a row dropped earlier (e.g.
        // a previous refresh saw nil terminalName because the host's
        // plugin wasn't installed yet) regains visibility once a fresh
        // event arrives with a now-valid plugin-resolved identity.
        let filterCtx = filterContext(forEvent: event)
        if sessionFilters.allSatisfy({ $0.shouldDisplay(filterCtx) }) {
            droppedSessionIds.remove(event.sessionId)
        } else if grantInferenceGrace(terminalName: event.terminalName, pid: event.pid, cwd: event.projectPath) {
            // tty-less host (Claude Code bg-pty-host etc.) whose
            // terminal_name hasn't resolved to a registered plugin yet —
            // async inference is now in flight; keep the row visible
            // until a later refresh re-judges it with the repaired
            // identity instead of flickering it out and back in.
            droppedSessionIds.remove(event.sessionId)
        } else {
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
        mergeLatestTaskIfAvailable(at: event.transcriptPath, into: &runtime)
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
            // taskDone / taskFailed derive livePreview from the assistant
            // transcript text, so mirror the progressNote logic above:
            // prefer commentaryAt (the entry's transcript-native timestamp)
            // over receivedAt (hook fire time), and reject staler values so
            // a hook snapshot taken before the final assistant text was
            // flushed can't clobber the fresher text a later transcript
            // sync just merged. waitingInput keeps receivedAt because its
            // preview is a hook-generated status string, not transcript text.
            let isTranscriptPreview: Bool = {
                switch event.kind {
                case .taskDone, .taskFailed: return true
                default: return false
                }
            }()
            let incomingAt = isTranscriptPreview
                ? (event.commentaryAt ?? event.receivedAt)
                : event.receivedAt
            let shouldOverwrite: Bool = {
                guard isTranscriptPreview, let existingAt = runtime.latestPreviewAt else { return true }
                return incomingAt >= existingAt
            }()
            if shouldOverwrite {
                runtime.latestPreview = livePreview
                runtime.latestPreviewAt = incomingAt
            }
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
        if shouldInferTerminalName(runtime.terminalName), let pid = runtime.pid {
            if let cached = inferredTerminalNameByPid[pid] {
                runtime.terminalName = cached
            } else {
                kickOffTerminalNameInference(forPid: pid, cwd: runtime.projectPath)
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
            signalCount += signals.count
            progressNoteCount += signals.filter { $0.kind == .progressNote }.count

            let before = runtime
            // Snap projectPath to JSONL launch dir (see restore comment above)
            // — keep the row title stable on the entry directory even after
            // hook events have nudged it to a focus subdir.
            if let launchDir = session.cwd?.nilIfEmpty {
                runtime.projectPath = launchDir
            } else if runtime.projectPath == nil {
                runtime.projectPath = session.projectPath.nilIfEmpty
            }
            RuntimeSessionEventApplier.merge(runtime: &runtime, signals: signals)
            mergeLatestTaskIfAvailable(from: session, into: &runtime)
            recoverClaudeProcessContextIfNeeded(for: &runtime)

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

    private func recoverClaudeProcessContextIfNeeded(for runtime: inout RuntimeSession) {
        guard runtime.provider == .claude else { return }
        let needsPid = runtime.pid == nil
        let needsTTY = runtime.tty?.nilIfEmpty == nil
        guard needsPid || needsTTY else { return }
        guard let projectPath = runtime.projectPath?.nilIfEmpty,
              let recovered = ProcessTreeWalker.findClaudeProcess(projectPath: projectPath) else {
            return
        }

        if needsPid {
            runtime.pid = Int32(recovered.pid)
        }
        if needsTTY {
            runtime.tty = recovered.tty
        }
        if shouldInferTerminalName(runtime.terminalName) {
            if let cached = inferredTerminalNameByPid[recovered.pid] {
                runtime.terminalName = cached
            } else {
                kickOffTerminalNameInference(forPid: recovered.pid, cwd: runtime.projectPath)
            }
        }
    }

    private func mergeLatestTaskIfAvailable(from session: Session, into runtime: inout RuntimeSession) {
        mergeLatestTaskIfAvailable(at: session.filePath, into: &runtime, incremental: false)
    }

    private func mergeLatestTaskIfAvailable(
        at transcriptPath: String?,
        into runtime: inout RuntimeSession,
        incremental: Bool = true
    ) {
        guard runtime.provider == .claude,
              let transcriptPath = transcriptPath?.nilIfEmpty else {
            return
        }

        // Capture inputs from the current runtime snapshot and schedule the
        // actual file IO + JSON parsing on a background queue. The 50 ms
        // per-session debounce coalesces hook-burst scans. `runtime` is
        // not mutated here; the async path writes results back via
        // `runtimeByKey[key]` directly and triggers `refresh()` if the
        // scan produced a change. Until that lands, the session keeps its
        // previously known `currentTask`, which is acceptable: the field
        // is a display-only summary that catches up within ~50 ms.
        let sessionKey = Self.key(provider: runtime.provider, sessionId: runtime.sessionId)
        let canIncrement = incremental && runtime.taskTranscriptPath == transcriptPath
        scheduleAsyncTaskScan(
            sessionKey: sessionKey,
            transcriptPath: transcriptPath,
            baseTasks: canIncrement ? runtime.runtimeTasks : nil,
            fromOffset: canIncrement ? runtime.taskTranscriptOffset : nil
        )
    }

    private func scheduleAsyncTaskScan(
        sessionKey: String,
        transcriptPath: String,
        baseTasks: [String: RuntimeTaskEntry]?,
        fromOffset: UInt64?
    ) {
        pendingTaskScans[sessionKey]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let scan = RuntimeSessionEventApplier.taskScanResult(
                at: transcriptPath,
                baseTasks: baseTasks,
                fromOffset: fromOffset
            )
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.applyTaskScanResult(
                        sessionKey: sessionKey,
                        transcriptPath: transcriptPath,
                        scan: scan
                    )
                }
            }
        }
        pendingTaskScans[sessionKey] = work
        Self.taskScanQueue.asyncAfter(deadline: .now() + taskScanDebounce, execute: work)
    }

    private func applyTaskScanResult(
        sessionKey: String,
        transcriptPath: String,
        scan: RuntimeTaskScanResult?
    ) {
        pendingTaskScans.removeValue(forKey: sessionKey)
        guard var runtime = runtimeByKey[sessionKey] else { return }
        guard let scan else { return }

        // Always update internal bookkeeping (transcript path + next offset).
        // These don't drive any UI, so changes here must NOT trigger
        // `refresh()` — doing so caused an infinite loop when `refresh`
        // → `repairIdleClaudeTaskSnapshots` → `mergeLatestTaskIfAvailable`
        // → scheduled another scan whose only delta was a fresh `nextOffset`.
        runtime.taskTranscriptPath = transcriptPath
        runtime.taskTranscriptOffset = scan.nextOffset

        // Only the display-visible fields (`runtimeTasks` + `currentTask`)
        // gate a `refresh()` so SwiftUI re-publishes the sessions array.
        var displayChanged = false
        if scan.clearsCurrentTask {
            if runtime.runtimeTasks != nil || runtime.currentTask != nil {
                runtime.runtimeTasks = nil
                runtime.currentTask = nil
                displayChanged = true
            }
        } else if let snapshot = scan.snapshot {
            if runtime.runtimeTasks != snapshot.tasks {
                runtime.runtimeTasks = snapshot.tasks
                displayChanged = true
            }
            if runtime.currentTask != snapshot.summary {
                runtime.currentTask = snapshot.summary
                runtime.lastActivityAt = max(runtime.lastActivityAt, snapshot.summary.updatedAt)
                displayChanged = true
            }
        }

        runtimeByKey[sessionKey] = runtime
        if displayChanged {
            refresh()
        }
    }

    private func filterContext(forEvent event: AttentionEvent) -> SessionFilterContext {
        // Judge against any cached pid→terminal-name inference so a
        // bg-pty-host row is filtered on its repaired identity, not the
        // raw `$TERM` fallback ("xterm-256color") the hook carried.
        var terminalName = event.terminalName
        if shouldInferTerminalName(terminalName), let pid = event.pid,
           let cached = inferredTerminalNameByPid[pid] {
            terminalName = cached
        }
        return SessionFilterContext(
            providerId: event.provider.rawValue,
            sessionId: event.sessionId,
            prompt: event.livePrompt,
            tty: event.tty,
            pid: event.pid,
            terminalName: terminalName,
            projectPath: event.projectPath,
            terminalStableID: event.terminalStableID?.nilIfEmpty,
            terminalTabID: event.terminalTabID?.nilIfEmpty,
            terminalWindowID: event.terminalWindowID?.nilIfEmpty,
            terminalSocket: event.terminalSocket?.nilIfEmpty
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
            projectPath: runtime.projectPath,
            terminalStableID: runtime.terminalStableID?.nilIfEmpty,
            terminalTabID: runtime.terminalTabID?.nilIfEmpty,
            terminalWindowID: runtime.terminalWindowID?.nilIfEmpty,
            terminalSocket: runtime.terminalSocket?.nilIfEmpty
        )
    }

    /// A terminal name needs (re)inference when it's missing or doesn't
    /// resolve to a registered terminal plugin — the latter covers
    /// Claude Code bg-pty-host hooks that fall `terminal_name` back to
    /// `$TERM` ("xterm-256color"), which no plugin claims.
    private func shouldInferTerminalName(_ name: String?) -> Bool {
        guard let name = name?.nilIfEmpty else { return true }
        return !TerminalRegistry.canFocusBackToTerminal(named: name)
    }

    /// record-time: should a not-yet-resolved tty-less session get a
    /// grace pass through the filter chain? Ensures inference is running.
    /// Grace is granted only before the first miss is recorded, but a
    /// retry still fires afterwards so a transient lsof/ps hiccup can
    /// recover on a later event.
    private func grantInferenceGrace(terminalName: String?, pid: pid_t?, cwd: String?) -> Bool {
        guard shouldInferTerminalName(terminalName), let pid else { return false }
        if inferredTerminalNameByPid[pid] != nil { return false }
        let firstAttempt = !inferenceFailedPids.contains(pid)
        kickOffTerminalNameInference(forPid: pid, cwd: cwd)
        return firstAttempt
    }

    /// refresh-time: don't garbage-collect a row whose terminal-name
    /// inference is still in flight (the grace pass from record()).
    private func inferenceGraceActive(terminalName: String?, pid: pid_t?) -> Bool {
        guard shouldInferTerminalName(terminalName), let pid else { return false }
        return pidInferenceInFlight.contains(pid)
    }

    /// Collapse Claude Code sessions that share one terminal tab down to
    /// a single visible row. A bg-pty fork child (e.g. a computer-use
    /// sub-session) resolves — via daemon topology — to the foreground
    /// `claude` pid that owns the tab; we group by that owner and keep
    /// the most-recently-active session in the tab — a working
    /// computer-use child surfaces its live activity, and the foreground
    /// conversation wins whenever the user is typing in it. (Always
    /// keeping the foreground pid froze the row on an idle main session
    /// while a bg child did all the work.)
    private func collapseSameTabSessions(_ runtimes: [RuntimeSession]) -> [RuntimeSession] {
        func owner(_ runtime: RuntimeSession) -> pid_t? {
            guard let pid = runtime.pid else { return nil }
            return inferredHostPidByPid[pid] ?? pid
        }
        var groups: [pid_t: [RuntimeSession]] = [:]
        var ungrouped: [RuntimeSession] = []
        for runtime in runtimes {
            if let owner = owner(runtime) { groups[owner, default: []].append(runtime) }
            else { ungrouped.append(runtime) }
        }
        var result = ungrouped
        var collapsedNotes: [String] = []
        for (ownerPid, members) in groups {
            if members.count == 1 {
                result.append(members[0])
            } else {
                let rep = members.max(by: { $0.lastActivityAt < $1.lastActivityAt })!
                result.append(rep)
                collapsedNotes.append(
                    "owner=\(ownerPid) kept=\(rep.sessionId.prefix(8)) of "
                    + "[\(members.map { String($0.sessionId.prefix(8)) }.joined(separator: ","))]")
            }
        }
        let signature = collapsedNotes.sorted().joined(separator: "; ")
        if signature != lastCollapseSignature {
            lastCollapseSignature = signature
            if !signature.isEmpty {
                DiagnosticLogger.shared.info("tab-collapse \(signature)")
            }
        }
        return result
    }

    private func kickOffTerminalNameInference(forPid pid: pid_t, cwd: String?) {
        guard !pidInferenceInFlight.contains(pid) else { return }
        pidInferenceInFlight.insert(pid)
        Task.detached(priority: .background) { [weak self] in
            // Claude Code daemon/bg-pty-host topology recovery FIRST: a
            // bg-pty session's parent chain ends at ClaudeCode.app (the
            // executor), which the Claude-app terminal plugin claims as a
            // "terminal" — so the plain walk would mislabel the row
            // `claude` and focus would activate the desktop app instead
            // of the real tab. Recovery hops daemon → spawned-by to the
            // foreground terminal (ghostty/iTerm) that actually launched
            // it. Falls back to the plain parent-chain walk for ordinary
            // (non-bg-pty) sessions where recovery returns nil.
            let recovered = ProcessTreeWalker.recoverClaudeHostTerminal(startingAt: pid, cwd: cwd)
            let proc = recovered?.terminal
                ?? ProcessTreeWalker.findTerminalProcessSynchronously(startingAt: pid)
            await MainActor.run {
                guard let self else { return }
                self.pidInferenceInFlight.remove(pid)
                guard let bundleId = proc?.bundleId,
                      let alias = TerminalRegistry.primaryTerminalNameAlias(forBundleId: bundleId) else {
                    // No host terminal found — record the miss so the
                    // grace pass stops re-extending. A genuinely
                    // terminal-less session gets hidden on next refresh.
                    self.inferenceFailedPids.insert(pid)
                    self.refresh()
                    return
                }
                self.inferredTerminalNameByPid[pid] = alias
                // Remember the foreground (tab-owning) pid so refresh can
                // collapse this session onto the main row of its tab.
                if let foregroundPid = recovered?.foregroundPid {
                    self.inferredHostPidByPid[pid] = foregroundPid
                }
                self.inferenceFailedPids.remove(pid)
                self.backfillTerminalName(forPid: pid, alias: alias)
                self.refresh()
            }
        }
    }

    private func backfillTerminalName(forPid pid: pid_t, alias: String) {
        var changed = false
        for (key, runtime) in runtimeByKey
            where runtime.pid == pid && shouldInferTerminalName(runtime.terminalName) {
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
        // rather than indefinitely carrying stale rows. We drop the
        // current runtime but do NOT blacklist the sessionId here —
        // refresh-time evaluation reflects moment-in-time runtime state
        // (e.g. terminalName might be nil on a row created before its
        // host's plugin was installed). The blacklist semantics are
        // reserved for record-time: first-event filter rejection signals
        // a genuinely synthetic prompt (Codex.app ambient prompts) that
        // shouldn't resurrect on later events. Refresh just garbage-
        // collects; if a future hook event arrives with valid identity
        // for one of these sessionIds, record's filter pass will reinstate
        // it.
        if !sessionFilters.isEmpty {
            for (key, runtime) in runtimeByKey {
                let ctx = filterContext(forRuntime: runtime)
                if !sessionFilters.allSatisfy({ $0.shouldDisplay(ctx) }),
                   !inferenceGraceActive(terminalName: runtime.terminalName, pid: runtime.pid) {
                    runtimeByKey.removeValue(forKey: key)
                }
            }
        }
        runtimeByKey = TerminalIdentityResolver.sanitizedTransientSurfaceCollisions(runtimeByKey
            .filter { shouldKeep(runtime: $0.value, cutoff: cutoff, now: now) }
            .mapValues { TerminalIdentityResolver.sanitized($0) })
        repairIdleClaudeTaskSnapshots()
        persistRuntime()

        displacedSessionIds = displacedSessionIds.filter { now.timeIntervalSince($0.value) < activeWindow }

        var merged: [String: ActiveSession] = [:]
        let visibleRuntimes = collapseSameTabSessions(
            runtimeByKey.values.filter { !displacedSessionIds.keys.contains($0.sessionId) }
        )
        for runtime in visibleRuntimes {
            let key = Self.key(provider: runtime.provider, sessionId: runtime.sessionId)
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
        // Pre-populate `cachedTriptychContent` for every session that ends up
        // in the @Published `sessions` array. The formatter's candidate chain
        // (activeToolsSummary / currentOperation / currentActivity / etc.)
        // is non-trivial and was a hot getter in Instruments — moving the
        // work here means SwiftUI's row body reads it as an O(1) struct
        // access, and we only pay the formatting cost on actual state
        // transitions instead of every re-render.
        sessions = fresh.prefix(maxItems).map { session in
            var copy = session
            copy.cachedTriptychContent = ProviderSessionDisplayFormatter(session: copy).content
            return copy
        }
    }

    private func repairIdleClaudeTaskSnapshots() {
        for (key, runtime) in runtimeByKey {
            guard runtime.provider == .claude,
                  runtime.currentTask != nil,
                  runtime.status != .running,
                  runtime.taskTranscriptPath?.nilIfEmpty != nil else {
                continue
            }
            var updated = runtime
            mergeLatestTaskIfAvailable(at: updated.taskTranscriptPath, into: &updated, incremental: false)
            if updated != runtime {
                runtimeByKey[key] = TerminalIdentityResolver.sanitized(updated)
            }
        }
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

    /// Completion cards should show the final assistant reply, not the last
    /// status preview. Stop hooks can fire before the transcript fully
    /// flushes, so let later transcript syncs replace the card body with the
    /// newest current-turn commentary.
    func lastCompletionPreview(provider: ProviderKind, sessionId: String) -> String? {
        let key = Self.key(provider: provider, sessionId: sessionId)
        if let runtime = runtimeByKey[key],
           let preview = completionPreview(
                progressNote: runtime.latestProgressNote,
                progressNoteAt: runtime.latestProgressNoteAt,
                promptAt: runtime.latestPromptAt,
                preview: runtime.latestPreview,
                previewAt: runtime.latestPreviewAt
           ) {
            return preview
        }
        if let session = sessions.first(where: { $0.focusKey == key }) {
            return completionPreview(
                progressNote: session.latestProgressNote,
                progressNoteAt: session.latestProgressNoteAt,
                promptAt: session.latestPromptAt,
                preview: session.latestPreview,
                previewAt: session.latestPreviewAt
            )
        }
        return nil
    }

    private func completionPreview(
        progressNote: String?,
        progressNoteAt: Date?,
        promptAt: Date?,
        preview: String?,
        previewAt: Date?
    ) -> String? {
        let currentTurnProgress: (text: String, at: Date?)? = {
            guard let text = progressNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let progressNoteAt,
                  promptAt.map({ progressNoteAt >= $0 }) ?? true else {
                return nil
            }
            return (text, progressNoteAt)
        }()
        let previewCandidate: (text: String, at: Date?)? = {
            guard let text = preview?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            return (text, previewAt)
        }()

        switch (currentTurnProgress, previewCandidate) {
        case let (progress?, preview?):
            if let progressAt = progress.at, let previewAt = preview.at {
                return progressAt >= previewAt ? progress.text : preview.text
            }
            return progress.at != nil ? progress.text : preview.text
        case let (progress?, nil):
            return progress.text
        case let (nil, preview?):
            return preview.text
        case (nil, nil):
            return nil
        }
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
