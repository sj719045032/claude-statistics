import Foundation
import ClaudeStatisticsKit
import SwiftUI

@MainActor
final class SessionDataStore: ObservableObject {
    // MARK: - Published state (UI binds to these)

    @Published var sessions: [Session] = []
    @Published var quickStats: [String: SessionQuickStats] = [:]
    @Published var parsedStats: [String: SessionStats] = [:] {
        didSet { parsedStatsVersion &+= 1 }
    }
    /// Monotonic version bumped whenever `parsedStats` is reassigned or
    /// mutated. Views memoize derived results (e.g. UsageView trend
    /// folds) keyed by this so cache invalidates the moment new parse
    /// data lands. PR4.
    @Published private(set) var parsedStatsVersion: UInt64 = 0
    @Published var selectedPeriod: StatsPeriod = .all { didSet { rebucket() } }
    @Published var weeklyResetDate: Date? { didSet { if selectedPeriod == .weekly { rebucket() } } }
    @Published var periodStats: [PeriodStats] = []
    @Published var isFullParseComplete = false
    @Published var parseProgress: String?
    @Published var parsePercent: Double?

    // MARK: - Internal state

    private var dirtySessionIds: Set<String> = []
    private var retrySessionIds: Set<String> = []
    private var retryAttemptCounts: [String: Int] = [:]
    private var retryTask: Task<Void, Never>?
    private var pendingRescan = false
    /// Pending dirty-id batch for in-flight coalescing. New watcher fires merge
    /// into this set while a `processDirtyBatch` task is running; the running
    /// task drains the merged set when it finishes.
    private var pendingDirtyIds: Set<String> = []
    private var pendingForceRescan = false
    private var isProcessingDirtyBatch = false
    private var isPopoverVisible = false
    private var watcher: (any SessionWatcher)?
    /// Idempotency flag for `start()`. Set on first start, cleared on
    /// `stop()`. PR2 (provider startup staging) calls `start()` lazily
    /// from `ProviderContextRegistry.ensureContext` after a previously
    /// cold store is first accessed, so start() must tolerate being
    /// invoked twice.
    private var isStarted = false

    /// The store binds to a `ProviderKind`, not to a specific
    /// `SessionProvider` instance. Every read of `provider` resolves
    /// through `ProviderRegistry.provider(for: kind)`, which is the
    /// single source of truth for plugin-supplied providers — when
    /// a plugin is hot-loaded, disabled, or re-registered, the store
    /// (and therefore every view bound to it) sees the new instance
    /// on the next access. Stored-instance form was the root cause
    /// of "Codex tab shows Claude usage": the registry was empty
    /// when the store was constructed during `bootstrap`, so the
    /// fallback Claude provider got baked in for life.
    let kind: ProviderKind
    var provider: any SessionProvider { ProviderRegistry.provider(for: kind) }
    private let db = DatabaseService.shared
    private let maxQueuedRetryAttempts = 3
    private let parseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        q.name = "com.claude-statistics.parse"
        return q
    }()

    init(kind: ProviderKind) {
        self.kind = kind
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        PerformanceTracer.measure("SessionDataStore.start") {
            db.open()

            watcher = provider.makeWatcher { [weak self] changedPaths in
                Task { @MainActor [weak self] in
                    self?.handleFileChanges(changedPaths)
                }
            }
            watcher?.start()
            initialLoad()
        }
    }

    func stop() {
        watcher?.stop()
        retryTask?.cancel()
        retryTask = nil
        parseQueue.cancelAllOperations()
        db.close()
        isStarted = false
    }

    // MARK: - Popover visibility

    func popoverDidOpen() {
        isPopoverVisible = true
        if !dirtySessionIds.isEmpty || !retrySessionIds.isEmpty {
            refreshDirtySessions()
        }
    }

    func popoverDidClose() {
        isPopoverVisible = false
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - Initial load

    private func initialLoad() {
        parseProgress = "Scanning sessions..."

        let provider = self.provider
        let providerKind = provider.kind
        let db = self.db
        Task.detached { [weak self] in
            guard let self else { return }
            let initialLoadSignpost = PerformanceTracer.begin("SessionDataStore.initialLoad")
            defer { PerformanceTracer.end("SessionDataStore.initialLoad", initialLoadSignpost) }
            let scannedSessions = SessionDeduplicator.deduplicate(provider.scanSessions(), provider: providerKind)
            DiagnosticLogger.shared.initialScanStarted(
                provider: providerKind.rawValue,
                sessionCount: scannedSessions.count
            )

            // Load DB cache and determine which sessions need reparsing
            let cache = db.loadAllCached(provider: providerKind)
            let indexedSessionIds = db.indexedSessionIds(provider: providerKind)
            var dirtyIds: [Session] = []
            var indexRepairIds: [Session] = []
            var quickMap: [String: SessionQuickStats] = [:]
            var statsMap: [String: SessionStats] = [:]

            // Classify dirty sessions: interrupted-parse (has quick but no stats — previous
            // run was killed mid-parse) vs new/changed. Interrupted ones are parsed first so
            // the user sees complete data as soon as possible after a crash recovery.
            var interruptedIds: [Session] = []
            var freshOrChangedIds: [Session] = []
            for session in scannedSessions {
                if db.needsReparse(sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, cache: cache) {
                    if let cached = cache[session.id], cached.sessionStats == nil, cached.quickStats != nil {
                        interruptedIds.append(session)
                    } else {
                        freshOrChangedIds.append(session)
                    }
                } else if let cached = cache[session.id] {
                    if let q = cached.quickStats { quickMap[session.id] = q }
                    if let s = cached.sessionStats { statsMap[session.id] = s }
                    if Self.needsSearchIndexRepair(
                        session: session,
                        cached: cached,
                        indexedSessionIds: indexedSessionIds
                    ) {
                        indexRepairIds.append(session)
                    }
                }
            }
            dirtyIds = interruptedIds + freshOrChangedIds

            if !interruptedIds.isEmpty {
                DiagnosticLogger.shared.info(
                    "[\(providerKind.rawValue)] Resuming parse — \(interruptedIds.count) sessions had incomplete cache from previous run (will parse first)"
                )
            }

            let initialQuickMap = quickMap
            let initialStatsMap = statsMap
            let initialHasStats = !statsMap.isEmpty
            let initialParseProgress: String? = dirtyIds.isEmpty ? nil : "Loading..."
            await MainActor.run {
                self.sessions = scannedSessions
                self.quickStats = initialQuickMap
                self.parsedStats = initialStatsMap
                if initialHasStats { self.rebucket() }
                self.parseProgress = initialParseProgress
            }

            if dirtyIds.isEmpty && indexRepairIds.isEmpty {
                // Clean up DB entries for deleted sessions
                let currentIds = Set(scannedSessions.map(\.id))
                let staleIds = Set(cache.keys).subtracting(currentIds)
                if !staleIds.isEmpty { db.removeSessions(provider: providerKind, staleIds) }

                await MainActor.run {
                    self.isFullParseComplete = true
                    self.parseProgress = nil
                    let totalMsgs = self.parsedStats.values.reduce(0) { $0 + $1.messageCount }
                    let totalToks = self.parsedStats.values.reduce(0) { $0 + $1.totalTokens }
                    DiagnosticLogger.shared.parsePhaseComplete(
                        totalSessions: self.parsedStats.count,
                        totalMessages: totalMsgs,
                        totalTokens: totalToks
                    )
                }
                return
            }

            // Quick parse dirty sessions
            var quickBySessionId: [String: SessionQuickStats] = [:]
            for session in dirtyIds {
                let quick = provider.parseQuickStats(at: session.filePath)
                db.saveQuickStats(provider: providerKind, sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, stats: quick)
                quickBySessionId[session.id] = quick
                await MainActor.run {
                    self.quickStats[session.id] = quick
                }
            }

            // Full parse + index dirty sessions (parse in parallel, DB write serial)
            let total = dirtyIds.count
            let parseStart = CFAbsoluteTimeGetCurrent()
            let batchSize = 8
            var processed = 0

            for batchStart in stride(from: 0, to: total, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, total)
                let batch = Array(dirtyIds[batchStart..<batchEnd])

                // Parse batch in parallel
                let results = await withTaskGroup(of: SessionParseOutcome.self) { group in
                    for session in batch {
                        let quick = quickBySessionId[session.id] ?? SessionQuickStats()
                        let cachedSession = cache[session.id]
                        group.addTask {
                            await SessionParseValidator.parse(
                                provider: provider,
                                session: session,
                                quick: quick,
                                cached: cachedSession
                            )
                        }
                    }
                    var batchResults: [SessionParseOutcome] = []
                    for await result in group {
                        batchResults.append(result)
                    }
                    return batchResults
                }

                // PR5: collect this batch's stats writes into one
                // request list and commit under a single SQLite
                // transaction (statements prepared once, reset per
                // request) instead of per-session BEGIN/COMMIT.
                let sessionsById = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
                var saveRequests: [DatabaseService.SaveSessionStatsRequest] = []
                for result in results {
                    guard let stats = result.committedStats else { continue }
                    guard let session = sessionsById[result.sessionId] else { continue }
                    saveRequests.append(DatabaseService.SaveSessionStatsRequest(
                        sessionId: session.id,
                        fileSize: session.fileSize,
                        mtime: session.lastModified,
                        stats: stats,
                        searchMessages: result.searchMessages
                    ))
                }
                db.saveSessionsStatsAndIndexes(provider: providerKind, requests: saveRequests)
                processed += results.count

                let processedCount = processed
                let shouldRebucket = processedCount % 20 < batchSize || processedCount == total
                await MainActor.run {
                    // Stage all parsedStats writes from this 8-session batch
                    // into a local copy and assign once. ObservableObject
                    // would otherwise fire `objectWillChange` per write
                    // (8x per batch) — SwiftUI does coalesce per RunLoop
                    // turn but Combine subscribers and downstream
                    // `removeDuplicates()` chains do not, so the staged
                    // assign also helps `@Published` consumers.
                    var staged = self.parsedStats
                    for result in results {
                        self.handleParseRetryState(for: result.sessionId, shouldRetry: result.shouldRetry)
                        if let stats = result.displayStats {
                            staged[result.sessionId] = stats
                        }
                    }
                    self.parsedStats = staged
                    self.parseProgress = "Parsing \(processedCount)/\(total)"
                    self.parsePercent = Double(processedCount) / Double(total)
                    if shouldRebucket {
                        self.rebucket()
                    }
                }
            }

            let parseTotal = CFAbsoluteTimeGetCurrent() - parseStart
            DiagnosticLogger.shared.parsePerf(
                sessions: total, subagentSessions: 0,
                parseTime: parseTotal, dbTime: 0, indexTime: 0
            )

            if !indexRepairIds.isEmpty {
                Self.repairSearchIndexes(
                    provider: provider,
                    db: db,
                    for: indexRepairIds,
                    cache: cache
                )
            }

            // Clean up DB entries for deleted sessions
            let currentIds = Set(scannedSessions.map(\.id))
            let staleIds = Set(cache.keys).subtracting(currentIds)
            if !staleIds.isEmpty { db.removeSessions(provider: providerKind, staleIds) }

            await MainActor.run {
                self.rebucket()
                self.isFullParseComplete = true
                self.parseProgress = nil
                self.parsePercent = nil

                let totalMsgs = self.parsedStats.values.reduce(0) { $0 + $1.messageCount }
                let totalToks = self.parsedStats.values.reduce(0) { $0 + $1.totalTokens }
                DiagnosticLogger.shared.parsePhaseComplete(
                    totalSessions: self.parsedStats.count,
                    totalMessages: totalMsgs,
                    totalTokens: totalToks
                )
            }
        }
    }

    // MARK: - File change handling

    private func handleFileChanges(_ changedPaths: Set<String>) {
        let changedIds = provider.changedSessionIds(for: changedPaths)
        let needsRescan = provider.shouldRescanSessions(for: changedPaths)
        guard needsRescan || !changedIds.isEmpty else { return }

        // Keep background session metadata fresh for the notch/island even when the
        // popover is closed. Parsing stays serialized on the store queue, so this
        // remains bounded while avoiding stale active-session previews.
        processDirtyIds(changedIds, forceRescan: needsRescan)
    }

    // MARK: - Dirty session processing

    private func refreshDirtySessions() {
        let ids = dirtySessionIds.union(retrySessionIds)
        dirtySessionIds.removeAll()
        retrySessionIds.removeAll()
        let needsRescan = pendingRescan
        pendingRescan = false
        processDirtyIds(ids, forceRescan: needsRescan)
    }

    private func processDirtyIds(_ ids: Set<String>, forceRescan: Bool = false) {
        pendingDirtyIds.formUnion(ids)
        if forceRescan { pendingForceRescan = true }
        guard !isProcessingDirtyBatch else { return }
        runNextDirtyBatch()
    }

    private func runNextDirtyBatch() {
        let ids = pendingDirtyIds
        let forceRescan = pendingForceRescan
        pendingDirtyIds.removeAll()
        pendingForceRescan = false

        guard forceRescan || !ids.isEmpty else {
            isProcessingDirtyBatch = false
            return
        }

        isProcessingDirtyBatch = true

        let provider = self.provider
        let providerKind = provider.kind
        let db = self.db
        // Snapshot the known sessions for the fast path. A new file that the
        // watcher already saw but we haven't scanned yet won't be in here, so
        // we promote to forceRescan when any dirty id is unknown.
        let knownSessions = self.sessions
        let knownIds = Set(knownSessions.map(\.id))
        let hasUnknownId = ids.contains { !knownIds.contains($0) }
        let effectiveForceRescan = forceRescan || hasUnknownId
        DiagnosticLogger.shared.verbose(
            "Session dirty process provider=\(providerKind.rawValue) ids=\(ids.count) forceRescan=\(effectiveForceRescan) fastPath=\(!effectiveForceRescan)"
        )
        Task.detached { [weak self] in
            guard let self else { return }

            let scannedSessions: [Session]
            let dirtySessions: [Session]
            let cache: [String: DatabaseService.CachedSession]
            if effectiveForceRescan {
                // Slow path: pick up new/deleted files and reparse anything whose
                // fingerprint changed against the cache. Use fingerprint-only
                // load (no JSON decode) for the staleness filter, then only
                // decode JSON for the actual dirty sessions as retry fallback.
                scannedSessions = SessionDeduplicator.deduplicate(provider.scanSessions(), provider: providerKind)
                let fingerprints = db.loadCacheFingerprints(provider: providerKind)
                await MainActor.run {
                    self.sessions = scannedSessions
                    self.cleanupDeletedSessions(current: scannedSessions)
                }
                dirtySessions = scannedSessions.filter {
                    ids.contains($0.id) || db.needsReparse(
                        sessionId: $0.id,
                        fileSize: $0.fileSize,
                        mtime: $0.lastModified,
                        fingerprints: fingerprints
                    )
                }
                cache = db.loadCached(provider: providerKind, sessionIds: Set(dirtySessions.map(\.id)))
            } else {
                // Fast path: watcher already told us exactly which sessions changed
                // and they all exist in the snapshot. Skip the full directory walk
                // and only load the cache rows we need as retry fallbacks.
                scannedSessions = knownSessions
                cache = db.loadCached(provider: providerKind, sessionIds: ids)
                dirtySessions = scannedSessions.filter { ids.contains($0.id) }
            }

            DiagnosticLogger.shared.verbose(
                "Session dirty matched provider=\(providerKind.rawValue) dirty=\(dirtySessions.count) scanned=\(scannedSessions.count)"
            )

            // Quick-parse + full-parse + index changed sessions
            let total = dirtySessions.count
            let showProgress = total > 3

            if showProgress {
                await MainActor.run { self.parseProgress = "Updating..." }
            }

            // PR5: batch all dirty-refresh stats writes into one
                    // transaction at end of loop. parsedStats / progress
            // still update per-iteration so the UI reflects each
            // parse completing; if the app crashes mid-loop the
            // unsaved sessions are simply re-detected as dirty on
            // next launch (file mtime > cached mtime).
            var saveRequests: [DatabaseService.SaveSessionStatsRequest] = []
            for (i, session) in dirtySessions.enumerated() {
                let quick = provider.parseQuickStats(at: session.filePath)
                db.saveQuickStats(provider: providerKind, sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, stats: quick)
                await MainActor.run { self.quickStats[session.id] = quick }

                let outcome = await SessionParseValidator.parse(
                    provider: provider,
                    session: session,
                    quick: quick,
                    cached: cache[session.id]
                )
                if let stats = outcome.committedStats {
                    saveRequests.append(DatabaseService.SaveSessionStatsRequest(
                        sessionId: session.id,
                        fileSize: session.fileSize,
                        mtime: session.lastModified,
                        stats: stats,
                        searchMessages: outcome.searchMessages
                    ))
                }
                await MainActor.run {
                    self.handleParseRetryState(for: session.id, shouldRetry: outcome.shouldRetry)
                    if let stats = outcome.displayStats {
                        self.parsedStats[session.id] = stats
                    }
                    if showProgress {
                        let processed = i + 1
                        self.parseProgress = "Updating \(processed)/\(total)"
                        self.parsePercent = Double(processed) / Double(total)
                    }
                }
            }
            db.saveSessionsStatsAndIndexes(provider: providerKind, requests: saveRequests)

            if showProgress {
                await MainActor.run {
                    self.parseProgress = nil
                    self.parsePercent = nil
                }
            }

            await MainActor.run {
                self.rebucket()
                // Drain anything queued while this batch was running. If nothing
                // is pending, runNextDirtyBatch() flips isProcessingDirtyBatch
                // back to false and exits.
                self.runNextDirtyBatch()
            }
        }
    }

    private func handleParseRetryState(for sessionId: String, shouldRetry: Bool) {
        if shouldRetry {
            let attempts = retryAttemptCounts[sessionId, default: 0] + 1
            retryAttemptCounts[sessionId] = attempts
            guard attempts < maxQueuedRetryAttempts else {
                retrySessionIds.remove(sessionId)
                DiagnosticLogger.shared.warning("Giving up queued retries for \(provider.kind.rawValue) session \(sessionId) after \(attempts) failures")
                return
            }
            retrySessionIds.insert(sessionId)
            scheduleRetryIfNeeded()
        } else {
            retrySessionIds.remove(sessionId)
            retryAttemptCounts.removeValue(forKey: sessionId)
        }
    }

    private func scheduleRetryIfNeeded() {
        guard isPopoverVisible, !retrySessionIds.isEmpty, retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.retryTask = nil
            guard self.isPopoverVisible, !self.retrySessionIds.isEmpty else { return }
            self.refreshDirtySessions()
        }
    }

    nonisolated private static func repairSearchIndexes(
        provider: any SessionProvider,
        db: DatabaseService,
        for sessions: [Session],
        cache: [String: DatabaseService.CachedSession]
    ) {
        guard !sessions.isEmpty else { return }
        DiagnosticLogger.shared.info("Repairing missing \(provider.kind.rawValue) search index for \(sessions.count) sessions")

        // PR5: collect repair writes into one batched transaction.
        var saveRequests: [DatabaseService.SaveSessionStatsRequest] = []
        for session in sessions {
            guard let cached = cache[session.id],
                  let stats = cached.sessionStats else { continue }
            let searchMessages = provider.parseSearchIndexMessages(at: session.filePath)
            saveRequests.append(DatabaseService.SaveSessionStatsRequest(
                sessionId: session.id,
                fileSize: session.fileSize,
                mtime: session.lastModified,
                stats: stats,
                searchMessages: searchMessages
            ))
        }
        db.saveSessionsStatsAndIndexes(provider: provider.kind, requests: saveRequests)
    }

    nonisolated private static func needsSearchIndexRepair(
        session: Session,
        cached: DatabaseService.CachedSession,
        indexedSessionIds: Set<String>
    ) -> Bool {
        guard cached.sessionStats != nil else { return false }
        guard !indexedSessionIds.contains(session.id) else { return false }

        let quick = cached.quickStats
        let stats = cached.sessionStats
        let likelySearchable = (quick?.messageCount ?? 0) > 0 ||
            (quick?.totalTokens ?? 0) > 0 ||
            (stats?.messageCount ?? 0) > 0 ||
            (stats?.totalTokens ?? 0) > 0 ||
            session.fileSize >= 4_096
        return likelySearchable
    }

    // MARK: - Rebucket (PR3 — runs off the main thread)

    /// Inputs captured on the main actor so the heavy fold can run on a
    /// background task. Sendable so the snapshot crosses the actor
    /// boundary without copying main-actor state.
    private struct RebucketSnapshot: Sendable {
        let parsedStats: [String: SessionStats]
        let sessions: [Session]
        let selectedPeriod: StatsPeriod
        let weeklyResetDate: Date?
        let allTimeLabel: String
    }

    /// All published outputs of a rebucket pass, computed off-main and
    /// applied atomically on the main actor under a generation guard.
    private struct RebucketResult: Sendable {
        let periodStats: [PeriodStats]
        let allTimeCost: Double
        let allTimeSessions: Int
        let allTimeTokens: Int
        let allTimeMessages: Int
        let visibleStats: [PeriodStats]
        let visibleModelBreakdown: [ModelUsage]
        let dailyHeatmap: [Date: DailyHeatmapBucket]
        let availableHeatmapYears: [Int]
        let topProjects: [TopProject]
    }

    /// Monotonic generation token. Each `rebucket()` call bumps it
    /// before dispatching the background compute; the background result
    /// is discarded if a newer call has bumped it again. Prevents a
    /// slow earlier compute (large parsedStats) from clobbering a faster
    /// later one (e.g. user rapidly switching period).
    private var rebucketGeneration: UInt64 = 0

    private func rebucket() {
        let signpostState = PerformanceTracer.begin("SessionDataStore.rebucket")
        defer { PerformanceTracer.end("SessionDataStore.rebucket", signpostState) }
        guard !parsedStats.isEmpty else { return }

        rebucketGeneration &+= 1
        let gen = rebucketGeneration
        let snapshot = RebucketSnapshot(
            parsedStats: parsedStats,
            sessions: sessions,
            selectedPeriod: selectedPeriod,
            weeklyResetDate: weeklyResetDate,
            allTimeLabel: LanguageManager.localizedString("period.all")
        )
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SessionDataStore.computeRebucket(snapshot: snapshot)
            await MainActor.run { [weak self] in
                guard let self, self.rebucketGeneration == gen else { return }
                self.applyRebucketResult(result)
            }
        }
    }

    /// Pure aggregation. Picks the all-time fast path or the per-period
    /// bucketing path based on the snapshot's `selectedPeriod`. Static +
    /// nonisolated so it can run from `Task.detached` without main-actor
    /// hops.
    private nonisolated static func computeRebucket(snapshot: RebucketSnapshot) -> RebucketResult {
        let allTimeSignpost = PerformanceTracer.begin("SessionDataStore.rebucketAllTime.compute")
        let allTimeAgg = SessionAllTimeAggregator.allTimeAggregates(
            parsedStats: snapshot.parsedStats,
            sessions: snapshot.sessions
        )
        PerformanceTracer.end("SessionDataStore.rebucketAllTime.compute", allTimeSignpost)

        if snapshot.selectedPeriod == .all {
            return computeAllTimeRebucket(snapshot: snapshot, allTimeAgg: allTimeAgg)
        }

        var buckets: [Date: PeriodStats] = [:]
        var periodSessionIds: [Date: Set<String>] = [:]
        var periodModelSessionIds: [Date: [String: Set<String>]] = [:]

        let resetDate = snapshot.weeklyResetDate
        // Use fiveMinSlices when weekly period has non-midnight boundary for accurate attribution
        let useFineSlices = snapshot.selectedPeriod == .weekly && resetDate != nil

        for (sessionId, stats) in snapshot.parsedStats {
            let slices = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            if !slices.isEmpty {
                for (sliceStart, slice) in slices {
                    let periodStart = snapshot.selectedPeriod.startOfPeriod(for: sliceStart, weeklyResetDate: resetDate)
                    if buckets[periodStart] == nil {
                        buckets[periodStart] = PeriodStats(
                            period: periodStart,
                            periodLabel: snapshot.selectedPeriod.label(for: periodStart, weeklyResetDate: resetDate),
                            chartLabel: snapshot.selectedPeriod.chartLabel(for: periodStart, weeklyResetDate: resetDate)
                        )
                    }
                    buckets[periodStart]?.accumulate(daySlice: slice)
                    periodSessionIds[periodStart, default: []].insert(sessionId)
                    for model in slice.modelBreakdown.keys {
                        var modelDict = periodModelSessionIds[periodStart] ?? [:]
                        var idSet = modelDict[model] ?? []
                        idSet.insert(sessionId)
                        modelDict[model] = idSet
                        periodModelSessionIds[periodStart] = modelDict
                    }
                }
            } else {
                // Fallback for sessions without day slices
                let session = snapshot.sessions.first { $0.id == sessionId }
                let date = stats.startTime ?? session?.lastModified ?? Date.distantPast
                let periodStart = snapshot.selectedPeriod.startOfPeriod(for: date, weeklyResetDate: resetDate)
                if buckets[periodStart] == nil {
                    buckets[periodStart] = PeriodStats(
                        period: periodStart,
                        periodLabel: snapshot.selectedPeriod.label(for: periodStart, weeklyResetDate: resetDate),
                        chartLabel: snapshot.selectedPeriod.chartLabel(for: periodStart, weeklyResetDate: resetDate)
                    )
                }
                buckets[periodStart]?.accumulate(stats: stats)
                periodSessionIds[periodStart, default: []].insert(sessionId)
                for model in stats.modelBreakdown.keys {
                    var modelDict = periodModelSessionIds[periodStart] ?? [:]
                    var idSet = modelDict[model] ?? []
                    idSet.insert(sessionId)
                    modelDict[model] = idSet
                    periodModelSessionIds[periodStart] = modelDict
                }
                if stats.modelBreakdown.isEmpty {
                    var modelDict = periodModelSessionIds[periodStart] ?? [:]
                    var idSet = modelDict[stats.model] ?? []
                    idSet.insert(sessionId)
                    modelDict[stats.model] = idSet
                    periodModelSessionIds[periodStart] = modelDict
                }
            }
        }

        // Set accurate session counts (one session counted once per period)
        for (period, ids) in periodSessionIds {
            buckets[period]?.sessionCount = ids.count
            if let modelDict = periodModelSessionIds[period] {
                for (model, modelIds) in modelDict {
                    if var usage = buckets[period]?.modelBreakdown[model] {
                        usage.sessionCount = modelIds.count
                        buckets[period]?.modelBreakdown[model] = usage
                    }
                }
            }
        }

        let periodStats = buckets.values.sorted { $0.period > $1.period }
        let visibleStats = Array(periodStats.prefix(snapshot.selectedPeriod.displayCount))

        return RebucketResult(
            periodStats: periodStats,
            allTimeCost: snapshot.parsedStats.values.reduce(0) { $0 + $1.estimatedCost },
            allTimeSessions: snapshot.parsedStats.count,
            allTimeTokens: snapshot.parsedStats.values.reduce(0) { $0 + $1.totalTokens },
            allTimeMessages: snapshot.parsedStats.values.reduce(0) { $0 + $1.messageCount },
            visibleStats: visibleStats,
            visibleModelBreakdown: computeModelBreakdown(for: visibleStats),
            dailyHeatmap: allTimeAgg.dailyHeatmap,
            availableHeatmapYears: allTimeAgg.availableYears,
            topProjects: allTimeAgg.topProjects
        )
    }

    /// All-Time scope produces a single aggregated `PeriodStats` spanning
    /// all data. `period.period` is intentionally `Date.distantPast` to
    /// line up with `StatsPeriod.all.startOfPeriod(for:)` —
    /// `aggregateTrendData` compares the two for equality when deciding
    /// which slices to include.
    private nonisolated static func computeAllTimeRebucket(snapshot: RebucketSnapshot,
                                                           allTimeAgg: AllTimeAggregates) -> RebucketResult {
        let label = snapshot.allTimeLabel
        var agg = PeriodStats(period: Date.distantPast, periodLabel: label, chartLabel: label)
        var modelSessionIds: [String: Set<String>] = [:]

        for (sessionId, stats) in snapshot.parsedStats {
            if stats.fiveMinSlices.isEmpty {
                agg.accumulate(stats: stats)
                for model in stats.modelBreakdown.keys {
                    modelSessionIds[model, default: []].insert(sessionId)
                }
                if stats.modelBreakdown.isEmpty {
                    modelSessionIds[stats.model, default: []].insert(sessionId)
                }
            } else {
                for (_, slice) in stats.fiveMinSlices {
                    agg.accumulate(daySlice: slice)
                    for model in slice.modelBreakdown.keys {
                        modelSessionIds[model, default: []].insert(sessionId)
                    }
                }
            }
        }
        agg.sessionCount = snapshot.parsedStats.count
        for (model, ids) in modelSessionIds {
            if var usage = agg.modelBreakdown[model] {
                usage.sessionCount = ids.count
                agg.modelBreakdown[model] = usage
            }
        }

        let periodStats = [agg]
        let visibleModels = computeModelBreakdown(for: periodStats)

        return RebucketResult(
            periodStats: periodStats,
            allTimeCost: agg.totalCost,
            allTimeSessions: agg.sessionCount,
            allTimeTokens: agg.totalTokens,
            allTimeMessages: agg.messageCount,
            visibleStats: periodStats,
            visibleModelBreakdown: visibleModels,
            dailyHeatmap: allTimeAgg.dailyHeatmap,
            availableHeatmapYears: allTimeAgg.availableYears,
            topProjects: allTimeAgg.topProjects
        )
    }

    /// Pure model-usage rollup across periods; static so both
    /// background compute and the main-actor `globalModelBreakdown`
    /// helper can share it.
    private nonisolated static func computeModelBreakdown(for periods: [PeriodStats]) -> [ModelUsage] {
        var combined: [String: ModelUsage] = [:]
        for period in periods {
            for (model, usage) in period.modelBreakdown {
                var existing = combined[model] ?? ModelUsage(model: model)
                existing.inputTokens += usage.inputTokens
                existing.outputTokens += usage.outputTokens
                existing.cost += usage.cost
                existing.sessionCount += usage.sessionCount
                if usage.isEstimated { existing.isEstimated = true }
                combined[model] = existing
            }
        }
        return combined.values.sorted { $0.cost > $1.cost }
    }

    /// Atomic write-back of a rebucket result to all published
    /// properties. Caller must check the generation token before
    /// invoking this so a stale background result never overwrites a
    /// newer one.
    private func applyRebucketResult(_ result: RebucketResult) {
        periodStats = result.periodStats
        allTimeCost = result.allTimeCost
        allTimeSessions = result.allTimeSessions
        allTimeTokens = result.allTimeTokens
        allTimeMessages = result.allTimeMessages
        visibleStats = result.visibleStats
        visibleModelBreakdown = result.visibleModelBreakdown
        _dailyHeatmapCache = result.dailyHeatmap
        _availableHeatmapYearsCache = result.availableHeatmapYears
        _topProjectsCache = result.topProjects
    }

    // MARK: - Top projects (all-time aggregation by project path)

    /// Aggregate projects by their `cwd` (or projectPath fallback) for a specific period.
    func aggregatePeriodTopProjects(for period: PeriodStats, periodType: StatsPeriod) async -> [TopProject] {
        // Snapshot main-actor state so the heavy fold runs off the UI thread.
        let currentSessions = sessions.isEmpty ? ProviderRegistry.provider(for: provider.kind).scanSessions() : sessions
        let snapshot = parsedStats
        let resetDate = weeklyResetDate
        return await Task.detached {
            SessionAllTimeAggregator.periodTopProjects(
                parsedStats: snapshot,
                sessions: currentSessions,
                period: period,
                periodType: periodType,
                weeklyResetDate: resetDate
            )
        }.value
    }

    /// Aggregate all sessions by their `cwd` (or projectPath fallback), sorted by estimated cost desc.
    /// Used by the All-Time view's "Top Projects" card.
    ///
    /// Backed by `_topProjectsCache` populated in `rebucket()` / `rebucketAllTime()`.
    var topProjects: [TopProject] { _topProjectsCache }
    @Published private var _topProjectsCache: [TopProject] = []

    // MARK: - Daily activity heatmap data

    /// Per-day aggregated cost + tokens for the heatmap in the All-Time view.
    /// Key is `startOfDay` in the user's local timezone.
    var dailyHeatmapData: [Date: DailyHeatmapBucket] { _dailyHeatmapCache }
    @Published private var _dailyHeatmapCache: [Date: DailyHeatmapBucket] = [:]

    /// Sorted-descending list of calendar years present in `dailyHeatmapData`.
    var availableHeatmapYears: [Int] { _availableHeatmapYearsCache }
    @Published private var _availableHeatmapYearsCache: [Int] = []

    // PR3: `recomputeAllTimeAggregates` was folded into `computeRebucket`
    // so heatmap / top-projects / aggregate stats all land in one
    // background pass instead of running a second main-thread sweep
    // afterwards.

    // MARK: - Delete

    func deleteSessions(_ ids: Set<String>) {
        let fm = FileManager.default
        for session in sessions where ids.contains(session.id) {
            try? fm.removeItem(atPath: session.filePath)
        }
        sessions.removeAll { ids.contains($0.id) }
        for id in ids {
            quickStats.removeValue(forKey: id)
            parsedStats.removeValue(forKey: id)
        }
        db.removeSessions(provider: provider.kind, ids)
        rebucket()
    }

    func deleteSession(_ id: String) {
        deleteSessions([id])
    }

    // MARK: - Force rescan

    func forceRescan() {
        dirtySessionIds.removeAll()
        parseQueue.cancelAllOperations()
        isFullParseComplete = false
        db.resetProviderCache(provider: provider.kind)
        quickStats.removeAll()
        parsedStats.removeAll()
        initialLoad()
    }

    // MARK: - Helpers

    private func cleanupDeletedSessions(current: [Session]) {
        let currentIds = Set(current.map(\.id))
        let staleIds = Set(parsedStats.keys).subtracting(currentIds)
        if staleIds.isEmpty { return }
        for id in staleIds {
            parsedStats.removeValue(forKey: id)
            quickStats.removeValue(forKey: id)
        }
        db.removeSessions(provider: provider.kind, staleIds)
    }

    /// Search messages via FTS index. Runs on a detached task so SQLite
    /// FTS work never blocks the main thread; callers gate stale results
    /// with their own generation token.
    func searchMessages(query: String) async -> [DatabaseService.SearchResult] {
        let db = self.db
        let kind = self.kind
        return await Task.detached(priority: .userInitiated) {
            let signpostState = PerformanceTracer.begin("SessionDataStore.searchMessages")
            defer { PerformanceTracer.end("SessionDataStore.searchMessages", signpostState) }
            return db.search(query: query, provider: kind)
        }.value
    }

    /// Returns the period-over-period comparison for `stat` vs the preceding period.
    /// `periodStats` is sorted newest-first, so the preceding period is at index+1.
    func periodComparison(for stat: PeriodStats) -> PeriodComparison? {
        guard let index = periodStats.firstIndex(where: { $0.id == stat.id }) else { return nil }
        let prevIndex = index + 1
        guard prevIndex < periodStats.count else { return nil }
        let prev = periodStats[prevIndex]

        func pct(_ cur: Double, _ pre: Double) -> Double {
            guard pre > 0 else { return 0 }
            return (cur - pre) / pre * 100
        }
        func pctI(_ cur: Int, _ pre: Int) -> Double {
            guard pre > 0 else { return 0 }
            return (Double(cur) - Double(pre)) / Double(pre) * 100
        }

        return PeriodComparison(
            costDelta: pct(stat.totalCost, prev.totalCost),
            tokenDelta: pctI(stat.totalTokens, prev.totalTokens),
            messageDelta: pctI(stat.messageCount, prev.messageCount),
            sessionDelta: pctI(stat.sessionCount, prev.sessionCount)
        )
    }

    // MARK: - Cached aggregates (updated in rebucket)

    @Published private(set) var allTimeCost: Double = 0
    @Published private(set) var allTimeSessions: Int = 0
    @Published private(set) var allTimeTokens: Int = 0
    @Published private(set) var allTimeMessages: Int = 0
    @Published private(set) var visibleStats: [PeriodStats] = []
    @Published private(set) var visibleModelBreakdown: [ModelUsage] = []

    /// Aggregate trend data for a given period from parsed session stats
    func aggregateTrendData(for period: PeriodStats, periodType: StatsPeriod) async -> [TrendDataPoint] {
        // Snapshot main-actor state so the heavy fold runs off the UI thread.
        let snapshot = parsedStats
        let snapshotSessions = sessions
        let resetDate = weeklyResetDate
        return await Task.detached {
            SessionTrendAggregator.trendData(
                parsedStats: snapshot,
                sessions: snapshotSessions,
                period: period,
                periodType: periodType,
                weeklyResetDate: resetDate
            )
        }.value
    }

    /// Aggregate raw token/cost usage for a rolling time window.
    func aggregateWindowTrendData(from start: Date, to end: Date, granularity: TrendGranularity, cumulative: Bool = false, modelFilter: ((String) -> Bool)? = nil) -> [TrendDataPoint] {
        SessionTrendAggregator.windowTrendData(
            parsedStats: parsedStats,
            from: start,
            to: end,
            granularity: granularity,
            cumulative: cumulative,
            modelFilter: modelFilter
        )
    }

    /// Snapshots parsedStats for the given sessions, then computes trend data off the main thread.
    func aggregateProjectTrendData(sessions: [Session], granularity: TrendGranularity = .day) async -> [TrendDataPoint] {
        let snapshot: [SessionStats] = sessions.compactMap { parsedStats[$0.id] }
        return await Task.detached {
            SessionTrendAggregator.projectTrend(stats: snapshot, granularity: granularity)
        }.value
    }

    /// Aggregates model breakdown for a specific set of sessions.
    func aggregateProjectModelBreakdown(sessions: [Session]) async -> [ModelUsage] {
        // Snapshot on main actor — the per-model fold below is pure but
        // touches `ModelPricing.estimateCost` which is fine off-main.
        let snapshot: [SessionStats] = sessions.compactMap { parsedStats[$0.id] }
        return await Task.detached {
            SessionTrendAggregator.projectModelBreakdown(stats: snapshot)
        }.value
    }

    func windowModelBreakdown(from start: Date, to end: Date, modelFilter: ((String) -> Bool)? = nil) -> [ModelUsage] {
        SessionTrendAggregator.windowModelBreakdown(
            parsedStats: parsedStats,
            from: start,
            to: end,
            modelFilter: modelFilter
        )
    }

    var globalModelBreakdown: [ModelUsage] {
        Self.computeModelBreakdown(for: periodStats)
    }

    func buildShareMetrics(for period: PeriodStats, periodType: StatsPeriod) -> ShareMetrics? {
        return ShareMetricsBuilder.build(
            sessions: sessions,
            parsedStats: parsedStats,
            providerKind: provider.kind,
            period: period,
            periodType: periodType,
            weeklyResetDate: weeklyResetDate
        )
    }

    func buildShareBaselineMetrics(for period: PeriodStats, periodType: StatsPeriod, lookbackDays: Int = 30) -> ShareMetrics? {
        let cal = Calendar.current
        let end = period.period
        let resolvedLookback = shareBaselineLookbackDays(for: periodType, fallback: lookbackDays)
        let start = cal.date(byAdding: .day, value: -resolvedLookback, to: end) ?? end
        return ShareMetricsBuilder.build(
            sessions: sessions,
            parsedStats: parsedStats,
            providerKind: provider.kind,
            scope: periodType,
            interval: DateInterval(start: start, end: end),
            scopeLabel: "Previous \(resolvedLookback)d"
        )
    }

    func buildShareRoleResult(for period: PeriodStats, periodType: StatsPeriod) -> ShareRoleResult? {
        guard let metrics = buildShareMetrics(for: period, periodType: periodType) else { return nil }
        let baseline = buildShareBaselineMetrics(for: period, periodType: periodType)
        let plugins = ProviderRegistry.currentSharedPluginRegistry()
        let pluginScores = SharePluginScoring.scores(
            plugins: plugins,
            context: metrics.evaluationContext(baseline: baseline)
        )
        let pluginThemes = SharePluginThemes.collect(plugins: plugins)
        return ShareRoleEngine.makeRoleResult(
            metrics: metrics,
            baseline: baseline,
            pluginScores: pluginScores,
            pluginThemes: pluginThemes
        )
    }

    func buildAllTimeShareRoleResult() -> ShareRoleResult? {
        guard let metrics = buildAllTimeShareMetrics(
            scopeLabel: LanguageManager.localizedString("share.scope.allTime")
        ) else {
            return nil
        }
        let baseline = buildAllTimeShareBaselineMetrics()
        let plugins = ProviderRegistry.currentSharedPluginRegistry()
        let pluginScores = SharePluginScoring.scores(
            plugins: plugins,
            context: metrics.evaluationContext(baseline: baseline)
        )
        let pluginThemes = SharePluginThemes.collect(plugins: plugins)
        return ShareRoleEngine.makeAllTimeRoleResult(
            metrics: metrics,
            baseline: baseline,
            pluginScores: pluginScores,
            pluginThemes: pluginThemes
        )
    }

    func buildAllTimeShareMetrics(scopeLabel: String? = nil) -> ShareMetrics? {
        let cal = Calendar.current
        let allDates = sessions.compactMap { session -> Date? in
            if let stats = parsedStats[session.id] {
                return stats.startTime ?? session.startTime ?? session.lastModified
            }
            return session.startTime ?? session.lastModified
        }
        guard let firstDate = allDates.min() else { return nil }

        let start = cal.startOfDay(for: firstDate)
        let end = Date()
        guard end > start else { return nil }

        return ShareMetricsBuilder.build(
            sessions: sessions,
            parsedStats: parsedStats,
            providerKind: provider.kind,
            scope: .all,
            interval: DateInterval(start: start, end: end),
            scopeLabel: scopeLabel ?? LanguageManager.localizedString("share.scope.allTime")
        )
    }

    func buildAllTimeShareBaselineMetrics(end: Date = Date()) -> ShareMetrics? {
        let cal = Calendar.current
        let baselineStart = cal.date(byAdding: .day, value: -365, to: end) ?? end
        return ShareMetricsBuilder.build(
            sessions: sessions,
            parsedStats: parsedStats,
            providerKind: provider.kind,
            scope: .all,
            interval: DateInterval(start: baselineStart, end: end),
            scopeLabel: LanguageManager.localizedString("share.scope.lastYear")
        )
    }

    private func shareBaselineLookbackDays(for periodType: StatsPeriod, fallback: Int) -> Int {
        switch periodType {
        case .all:
            return 730
        case .daily:
            return 14
        case .weekly:
            return 56
        case .monthly:
            return 365
        }
    }

    // PR3: pure `modelBreakdown(for:)` lives as
    // `Self.computeModelBreakdown` near the rebucket pipeline so
    // off-main compute can call it directly.
}
