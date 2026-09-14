import Foundation
import ClaudeStatisticsKit
import SwiftUI
import Combine

@MainActor
final class SessionDataStore: ObservableObject {
    private static let parserRevisionMetadataKey = "session.parserRevision"

    // MARK: - Published state (UI binds to these)

    @Published var sessions: [Session] = []
    @Published var quickStats: [String: SessionQuickStats] = [:]
    @Published var parsedStats: [String: SessionStats] = [:] {
        didSet {
            parsedStatsVersion &+= 1
            let changed = nextChangedStatsIDs ?? Set(oldValue.keys).union(parsedStats.keys)
            for id in changed { statsRevisions[id] = parsedStats[id] == nil ? nil : parsedStatsVersion }
        }
    }
    private var statsRevisions: [String: UInt64] = [:]
    private var nextChangedStatsIDs: Set<String>?
    private let aggregateEngine = IncrementalSessionAggregator()
    private var aggregateSubscriptions: Set<AnyCancellable> = []
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
    /// Sessions that had dirty events since last transcript archive.
    private var dirtyArchiveIds: Set<String> = []
    private var archiveTimer: Task<Void, Never>?
    /// Pending dirty-id batch for in-flight coalescing. New watcher fires merge
    /// into this set while a `processDirtyBatch` task is running; the running
    /// task drains the merged set when it finishes.
    private var pendingDirtyIds: Set<String> = []
    private var pendingForceRescan = false
    /// Watcher paths whose rescan decision is still to be made. The provider
    /// answers in the batch task, off the main actor: answering can read
    /// provider state (Codex reads its thread table on every WAL event).
    private var pendingRescanCandidates: Set<String> = []
    private var isProcessingDirtyBatch = false
    private var isPopoverVisible = false
    private var needsRebucket = false
    private var watcher: (any SessionWatcher)?
    /// Idempotency flag for `start()`. Set on first start, cleared on
    /// `stop()`. PR2 (provider startup staging) calls `start()` lazily
    /// from `ProviderContextRegistry.ensureContext` after a previously
    /// cold store is first accessed, so start() must tolerate being
    /// invoked twice.
    private var isStarted = false
    private var workGeneration: UInt64 = 0
    private var initialLoadTask: Task<Void, Never>?
    private var dirtyBatchTask: Task<Void, Never>?
    private var archiveWorkTask: Task<Void, Never>?
    private var legacyRelocationTask: Task<Void, Never>?

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
    var provider: any SessionProvider { providerOverride ?? ProviderRegistry.provider(for: kind) }
    private let providerOverride: (any SessionProvider)?
    private let db: DatabaseService
    private let scheduler: BackgroundWorkScheduler
    private let maxQueuedRetryAttempts = 3

    init(kind: ProviderKind, provider: (any SessionProvider)? = nil,
         database: DatabaseService = .shared, scheduler: BackgroundWorkScheduler = .shared) {
        self.kind = kind
        self.providerOverride = provider
        self.db = database
        self.scheduler = scheduler
        for name in [ModelPricing.didChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // Invalidate view-side derived caches without marking raw
                    // session contributions dirty or reparsing any transcript.
                    self?.parsedStatsVersion &+= 1
                    self?.rebucket()
                }
                .store(in: &aggregateSubscriptions)
        }
    }

    private func publishParsedStats(_ value: [String: SessionStats], changed: Set<String>) {
        nextChangedStatsIDs = changed
        parsedStats = value
        nextChangedStatsIDs = nil
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
            startArchiveTimer()
            initialLoad()
        }
    }

    func stop() {
        isPopoverVisible = false
        watcher?.stop()
        retryTask?.cancel()
        retryTask = nil
        archiveTimer?.cancel()
        archiveTimer = nil
        cancelBackgroundWork()
        // The connection is shared: stopping one provider must not close it
        // underneath the other providers.
        isStarted = false
    }

    private func cancelBackgroundWork() {
        workGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil
        retrySessionIds.removeAll()
        retryAttemptCounts.removeAll()
        initialLoadTask?.cancel()
        initialLoadTask = nil
        dirtyBatchTask?.cancel()
        dirtyBatchTask = nil
        archiveWorkTask?.cancel()
        archiveWorkTask = nil
        legacyRelocationTask?.cancel()
        legacyRelocationTask = nil
        rebucketWorker.cancel()
        pendingDirtyIds.removeAll()
        pendingForceRescan = false
        pendingRescanCandidates.removeAll()
        isProcessingDirtyBatch = false
    }

    private func startArchiveTimer() {
        archiveTimer?.cancel()
        archiveTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1 * 60 * 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.archiveDirtySessions()
            }
        }
    }

    private func archiveDirtySessions() {
        let ids = dirtyArchiveIds
        dirtyArchiveIds.removeAll()
        guard !ids.isEmpty else { return }
        let sessions = self.sessions.filter { ids.contains($0.id) && !$0.isArchived && !$0.filePath.isEmpty }
        guard !sessions.isEmpty else { return }
        let providerKind = self.kind
        let scheduler = self.scheduler
        let db = self.db
        archiveWorkTask?.cancel()
        archiveWorkTask = Task.detached {
            for session in sessions {
                guard !Task.isCancelled else { return }
                await Self.archiveTranscriptIfNeeded(db: db, provider: providerKind, session: session, scheduler: scheduler)
            }
            DiagnosticLogger.shared.info("[\(providerKind.rawValue)] Periodic archive: compressed \(sessions.count) active sessions")
        }
    }

    // MARK: - Popover visibility

    func popoverDidOpen() {
        isPopoverVisible = true
        if needsRebucket { rebucket() }
        if !dirtySessionIds.isEmpty || !retrySessionIds.isEmpty {
            refreshDirtySessions()
        }
    }

    func popoverDidClose() {
        isPopoverVisible = false
        if rebucketWorker.isWorking {
            needsRebucket = true
            rebucketWorker.cancel()
        }
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - Initial load

    private func initialLoad() {
        parseProgress = "Scanning sessions..."

        let provider = self.provider
        let providerKind = provider.kind
        let db = self.db
        let scheduler = self.scheduler
        let generation = workGeneration
        initialLoadTask = Task.detached { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.workGeneration == generation else { return }
                    self.initialLoadTask = nil
                    self.runNextDirtyBatch()
                }
            }
            let initialLoadSignpost = PerformanceTracer.begin("SessionDataStore.initialLoad")
            defer { PerformanceTracer.end("SessionDataStore.initialLoad", initialLoadSignpost) }
            guard let scannedSessions = try? await scheduler.run(operation: {
                SessionDeduplicator.deduplicate(provider.scanSessions(), provider: providerKind)
            }) else { return }
            guard !Task.isCancelled else { return }
            DiagnosticLogger.shared.initialScanStarted(
                provider: providerKind.rawValue,
                sessionCount: scannedSessions.count
            )

            // Load DB cache and determine which sessions need reparsing
            guard let cache = try? await scheduler.run(operation: {
                db.loadAllCached(provider: providerKind)
            }) else { return }
            guard !Task.isCancelled else { return }
            let parserRevisionChangedIds = Set(scannedSessions.compactMap { session -> String? in
                guard let revision = session.metadata[Self.parserRevisionMetadataKey],
                      let cached = cache[session.id],
                      cached.metadata[Self.parserRevisionMetadataKey] != revision else {
                    return nil
                }
                return session.id
            })
            if !parserRevisionChangedIds.isEmpty {
                db.invalidateSessionParseCaches(
                    provider: providerKind,
                    sessionIds: parserRevisionChangedIds
                )
                DiagnosticLogger.shared.info(
                    "[\(providerKind.rawValue)] Parser revision changed — rebuilding \(parserRevisionChangedIds.count) session caches"
                )
            }
            db.saveSessionMetadata(provider: providerKind, sessions: scannedSessions)
            let indexedSessionIds = db.sessionsWithCompleteIndex(provider: providerKind)
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
                guard !Task.isCancelled else { return }
                // Show the last committed values while validating changed data.
                if let cached = cache[session.id] {
                    if let quick = cached.quickStats { quickMap[session.id] = quick }
                    if let stats = cached.sessionStats { statsMap[session.id] = stats }
                }
                if provider is any CheckpointedSessionDataProvider || parserRevisionChangedIds.contains(session.id) ||
                    db.needsReparse(sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, cache: cache) {
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

            // Synthesize archived sessions from DB cache for sessions whose
            // .jsonl files have been deleted (e.g. by CC's 30-day cleanup).
            let scannedIds = Set(scannedSessions.map(\.id))
            var archivedSessions: [Session] = []
            for (sessionId, cached) in cache where !scannedIds.contains(sessionId) {
                guard cached.sessionStats != nil else { continue }
                let startTime: Date? = cached.quickStats?.startTime
                    ?? cached.sessionStats?.startTime
                var session = Session(
                    id: sessionId,
                    externalID: sessionId,
                    provider: providerKind.rawValue,
                    projectPath: cached.projectPath ?? "",
                    filePath: "",
                    startTime: startTime,
                    lastModified: cached.mtime,
                    fileSize: 0,
                    cwd: cached.cwd,
                    metadata: cached.metadata
                )
                session.isArchived = true
                archivedSessions.append(session)
                if let q = cached.quickStats { quickMap[sessionId] = q }
                if let s = cached.sessionStats { statsMap[sessionId] = s }
            }
            if !archivedSessions.isEmpty {
                DiagnosticLogger.shared.info(
                    "[\(providerKind.rawValue)] Loaded \(archivedSessions.count) archived sessions from DB cache"
                )
            }
            let allSessions = scannedSessions + archivedSessions

            let initialQuickMap = quickMap
            let initialStatsMap = statsMap
            let initialHasStats = !statsMap.isEmpty
            let initialParseProgress: String? = dirtyIds.isEmpty ? nil : "Loading..."
            await MainActor.run {
                guard self.workGeneration == generation else { return }
                self.sessions = allSessions
                self.quickStats = initialQuickMap
                self.parsedStats = initialStatsMap
                if initialHasStats { self.rebucket() }
                self.parseProgress = initialParseProgress
            }

            if dirtyIds.isEmpty && indexRepairIds.isEmpty {
                await MainActor.run {
                    guard self.workGeneration == generation else { return }
                    self.isFullParseComplete = true
                    self.startLegacyBlobRelocation()
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

            // One complete session transaction at a time per store. Providers
            // still share the global concurrent queue, but a completed parser's
            // large FTS payload is committed/released before reading another file.
            let total = dirtyIds.count
            let parseStart = CFAbsoluteTimeGetCurrent()
            var newArchiveSessions: [Session] = []
            for (index, session) in dirtyIds.enumerated() {
                guard !Task.isCancelled else { return }
                let quick: SessionQuickStats
                if provider is any CheckpointedSessionDataProvider {
                    quick = cache[session.id]?.quickStats ?? SessionQuickStats()
                } else {
                    guard let parsed = try? await scheduler.run(
                        estimatedBytes: min(max(1, session.fileSize), Int64.max / 4) * 4,
                        operation: { provider.parseQuickStats(at: session.filePath) }
                    ) else { return }
                    quick = parsed
                    db.saveQuickStats(provider: providerKind, sessionId: session.id,
                                      fileSize: session.fileSize, mtime: session.lastModified, stats: quick)
                }
                let result = await SessionParseValidator.parseAndCommit(
                    provider: provider, session: session, quick: quick, cached: cache[session.id],
                    database: db, scheduler: scheduler
                )
                guard !Task.isCancelled else { return }
                if result.stats != nil, cache[session.id]?.hasTranscript != true {
                    newArchiveSessions.append(session)
                }
                let processedCount = index + 1
                await MainActor.run {
                    guard self.workGeneration == generation else { return }
                    self.handleParseRetryState(for: session.id, shouldRetry: result.shouldRetry)
                    if let stats = result.stats {
                        self.quickStats[session.id] = result.quickStats
                        var staged = self.parsedStats
                        staged[session.id] = stats
                        self.publishParsedStats(staged, changed: [session.id])
                    }
                    self.parseProgress = "Parsing \(processedCount)/\(total)"
                    self.parsePercent = Double(processedCount) / Double(total)
                    if processedCount % 20 == 0 || processedCount == total {
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
                guard !Task.isCancelled else { return }
                await Self.repairSearchIndexes(
                    provider: provider,
                    db: db,
                    for: indexRepairIds,
                    cache: cache, scheduler: scheduler
                )
            }

            // Backfill transcript blobs for sessions that have files on
            // disk and stats in cache but no archived transcript yet.
            let newArchiveIDs = Set(newArchiveSessions.map(\.id))
            let sessionsNeedingBackfill = newArchiveSessions + scannedSessions.filter { session in
                guard !newArchiveIDs.contains(session.id) else { return false }
                guard let cached = cache[session.id],
                      cached.sessionStats != nil,
                      !cached.hasTranscript else { return false }
                return true
            }
            if !sessionsNeedingBackfill.isEmpty {
                DiagnosticLogger.shared.info(
                    "[\(providerKind.rawValue)] Backfilling transcript archive for \(sessionsNeedingBackfill.count) sessions"
                )
                for session in sessionsNeedingBackfill {
                    guard !Task.isCancelled else { return }
                    await Self.archiveTranscriptIfNeeded(
                        db: db, provider: providerKind, session: session, scheduler: scheduler
                    )
                }
            }

            await MainActor.run {
                guard self.workGeneration == generation else { return }
                self.rebucket()
                self.isFullParseComplete = true
                self.startLegacyBlobRelocation()
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
        guard isStarted, !changedPaths.isEmpty else { return }
        let changedIds = provider.changedSessionIds(for: changedPaths)

        // Keep background session metadata fresh for the notch/island even when the
        // popover is closed. Parsing stays serialized on the store queue, so this
        // remains bounded while avoiding stale active-session previews. Whether
        // the batch needs a full scan is decided in the batch task, not here.
        processDirtyIds(changedIds, rescanCandidates: changedPaths)
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

    private func processDirtyIds(_ ids: Set<String>, forceRescan: Bool = false,
                                 rescanCandidates: Set<String> = []) {
        pendingDirtyIds.formUnion(ids)
        pendingRescanCandidates.formUnion(rescanCandidates)
        if forceRescan { pendingForceRescan = true }
        guard !isProcessingDirtyBatch, initialLoadTask == nil else { return }
        runNextDirtyBatch()
    }

    private func runNextDirtyBatch() {
        let ids = pendingDirtyIds
        let forceRescan = pendingForceRescan
        let rescanCandidates = pendingRescanCandidates
        pendingDirtyIds.removeAll()
        pendingForceRescan = false
        pendingRescanCandidates.removeAll()

        guard forceRescan || !ids.isEmpty || !rescanCandidates.isEmpty else {
            isProcessingDirtyBatch = false
            return
        }

        isProcessingDirtyBatch = true

        let provider = self.provider
        let providerKind = provider.kind
        let db = self.db
        let scheduler = self.scheduler
        // Snapshot the known sessions for the fast path. A new file that the
        // watcher already saw but we haven't scanned yet won't be in here, so
        // we promote to forceRescan when any dirty id is unknown.
        let knownSessions = self.sessions
        let knownIds = Set(knownSessions.map(\.id))
        let hasUnknownId = ids.contains { !knownIds.contains($0) }
        let knownForceRescan = forceRescan || hasUnknownId
        let generation = workGeneration
        dirtyBatchTask = Task.detached { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }

            let effectiveForceRescan = knownForceRescan ||
                (!rescanCandidates.isEmpty && provider.shouldRescanSessions(for: rescanCandidates))
            DiagnosticLogger.shared.verbose(
                "Session dirty process provider=\(providerKind.rawValue) ids=\(ids.count) forceRescan=\(effectiveForceRescan) fastPath=\(!effectiveForceRescan)"
            )
            // Only provider-state events and the provider said nothing a scan
            // reads has changed: nothing to do. Drain the queue exactly as a
            // finished batch does.
            guard effectiveForceRescan || !ids.isEmpty else {
                await MainActor.run {
                    guard self.workGeneration == generation else { return }
                    self.dirtyBatchTask = nil
                    self.runNextDirtyBatch()
                }
                return
            }

            let scannedSessions: [Session]
            let dirtySessions: [Session]
            let cache: [String: DatabaseService.CachedSession]
            if effectiveForceRescan {
                // Slow path: pick up new/deleted files and reparse anything whose
                // fingerprint changed against the cache. Use fingerprint-only
                // load (no JSON decode) for the staleness filter, then only
                // decode JSON for the actual dirty sessions as retry fallback.
                guard let scanned = try? await scheduler.run(operation: {
                    SessionDeduplicator.deduplicate(provider.scanSessions(), provider: providerKind)
                }) else { return }
                scannedSessions = scanned
                guard !Task.isCancelled else { return }
                db.saveSessionMetadata(provider: providerKind, sessions: scannedSessions)
                let fingerprints = db.loadCacheFingerprints(provider: providerKind)
                await MainActor.run {
                    guard self.workGeneration == generation else { return }
                    // Preserve archived sessions that have no files on disk
                    let archivedSessions = self.sessions.filter(\.isArchived)
                    self.sessions = scannedSessions + archivedSessions
                }
                dirtySessions = scannedSessions.filter {
                    ids.contains($0.id) || db.needsReparse(
                        sessionId: $0.id,
                        fileSize: $0.fileSize,
                        mtime: $0.lastModified,
                        fingerprints: fingerprints
                    )
                }
                let dirtyIDs = Set(dirtySessions.map(\.id))
                guard let loaded = try? await scheduler.run(operation: {
                    db.loadCached(provider: providerKind, sessionIds: dirtyIDs)
                }) else { return }
                cache = loaded
            } else {
                // Fast path: watcher already told us exactly which sessions changed
                // and they all exist in the snapshot. Skip the full directory walk
                // and only load the cache rows we need as retry fallbacks.
                scannedSessions = knownSessions
                guard let loaded = try? await scheduler.run(operation: {
                    db.loadCached(provider: providerKind, sessionIds: ids)
                }) else { return }
                cache = loaded
                dirtySessions = scannedSessions.filter { ids.contains($0.id) }
            }

            DiagnosticLogger.shared.verbose(
                "Session dirty matched provider=\(providerKind.rawValue) dirty=\(dirtySessions.count) scanned=\(scannedSessions.count)"
            )

            // Quick-parse + full-parse + index changed sessions
            let total = dirtySessions.count
            let showProgress = total > 3

            if showProgress {
                await MainActor.run {
                    guard self.workGeneration == generation else { return }
                    self.parseProgress = "Updating..."
                }
            }

            var stagedStats: [String: SessionStats] = [:]
            var stagedQuick: [String: SessionQuickStats] = [:]
            for (i, session) in dirtySessions.enumerated() {
                guard !Task.isCancelled else { return }
                guard FileManager.default.fileExists(atPath: session.filePath) else { continue }
                let quick: SessionQuickStats
                if provider is any CheckpointedSessionDataProvider {
                    quick = cache[session.id]?.quickStats ?? SessionQuickStats()
                } else {
                    // Legacy APIs require complete Data and cannot return an
                    // incremental FTS projection. Use their combined parser,
                    // not an extra full-file read to probe incremental support.
                    guard let parsed = try? await scheduler.run(
                        estimatedBytes: min(max(1, session.fileSize), Int64.max / 4) * 4,
                        operation: { provider.parseQuickStats(at: session.filePath) }
                    ) else { return }
                    quick = parsed
                }
                let outcome = await SessionParseValidator.parseAndCommit(
                    provider: provider, session: session, quick: quick,
                    cached: cache[session.id], database: db, scheduler: scheduler
                )
                guard !Task.isCancelled else { return }
                if let stats = outcome.stats {
                    stagedStats[session.id] = stats
                    stagedQuick[session.id] = outcome.quickStats
                }
                await MainActor.run {
                    guard self.workGeneration == generation else { return }
                    self.handleParseRetryState(for: session.id, shouldRetry: outcome.shouldRetry)
                    if showProgress {
                        let processed = i + 1
                        self.parseProgress = "Updating \(processed)/\(total)"
                        self.parsePercent = Double(processed) / Double(total)
                    }
                }
            }
            guard !Task.isCancelled else { return }

            let committedStats = stagedStats
            let committedQuick = stagedQuick
            let metadataChanged = effectiveForceRescan && scannedSessions != knownSessions.filter { !$0.isArchived }
            let parsedSessionIds = Set(committedStats.keys)
            await MainActor.run {
                guard self.workGeneration == generation else { return }
                if !committedStats.isEmpty {
                    var staged = self.parsedStats
                    staged.merge(committedStats) { _, new in new }
                    self.publishParsedStats(staged, changed: Set(committedStats.keys))
                    self.quickStats.merge(committedQuick) { _, new in new }
                }
                self.dirtyArchiveIds.formUnion(parsedSessionIds)
            }

            if showProgress {
                await MainActor.run {
                    guard self.workGeneration == generation else { return }
                    self.parseProgress = nil
                    self.parsePercent = nil
                }
            }

            await MainActor.run {
                guard self.workGeneration == generation else { return }
                self.dirtyBatchTask = nil
                if !committedStats.isEmpty || metadataChanged { self.rebucket() }
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
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            guard self.isPopoverVisible, !self.retrySessionIds.isEmpty else { return }
            self.refreshDirtySessions()
        }
    }

    nonisolated static func repairSearchIndexes(
        provider: any SessionProvider,
        db: DatabaseService,
        for sessions: [Session],
        cache: [String: DatabaseService.CachedSession],
        scheduler: BackgroundWorkScheduler = .shared
    ) async {
        guard !sessions.isEmpty else { return }
        DiagnosticLogger.shared.info("Repairing missing \(provider.kind.rawValue) search index for \(sessions.count) sessions")

        // Commit/release one session before reading the next. Retaining every
        // missing index until the end made cold repair grow with all history.
        for session in sessions {
            guard !Task.isCancelled else { return }
            guard let cached = cache[session.id],
                  let stats = cached.sessionStats else { continue }
            _ = try? await scheduler.run(
                estimatedBytes: min(max(1, session.fileSize), Int64.max / 4) * 4
            ) {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let before = try TranscriptFileSnapshot.read(at: session.filePath)
                    let messages = provider.parseSearchIndexMessages(at: session.filePath)
                    try Task.checkCancellation()
                    guard try TranscriptFileSnapshot.read(at: session.filePath) == before else { return false }
                    return db.saveSessionsStatsAndIndexes(provider: provider.kind, requests: [
                        DatabaseService.SaveSessionStatsRequest(
                            sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified,
                            stats: stats, searchMessages: messages)
                    ])
                }
            }
        }
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

    // MARK: - Transcript Archival

    /// Move this provider's pre-v14 archives out of their `session_cache`
    /// rows, one session at a time at background priority. Inline, each blob
    /// is walked by every read or update of the columns stored after it —
    /// parser checkpoints, index completeness, metadata — on every parse.
    private func startLegacyBlobRelocation() {
        guard legacyRelocationTask == nil else { return }
        let db = self.db
        let providerKind = self.kind
        let scheduler = self.scheduler
        legacyRelocationTask = Task.detached {
            db.discardIncompleteLegacyRelocations(provider: providerKind)
            let ids = db.sessionsWithInlineLegacyTranscripts(provider: providerKind)
            guard !ids.isEmpty else { return }
            var moved = 0
            for id in ids {
                guard !Task.isCancelled else { return }
                let relocated = (try? await scheduler.run(
                    estimatedBytes: Int64(DatabaseService.legacyRelocationChunkBytes) * 2,
                    priority: .background
                ) {
                    db.relocateInlineLegacyTranscript(provider: providerKind, sessionId: id)
                }) ?? false
                if relocated { moved += 1 }
            }
            // The copies went through the WAL; hand its space back.
            if moved > 0 { db.checkpoint() }
            DiagnosticLogger.shared.info(
                "[\(providerKind.rawValue)] Moved \(moved)/\(ids.count) pre-v14 transcript archives out of session rows"
            )
        }
    }

    nonisolated private static func archiveTranscriptIfNeeded(
        db: DatabaseService,
        provider: ProviderKind,
        session: Session,
        scheduler: BackgroundWorkScheduler = .shared
    ) async {
        guard !session.isArchived, !session.filePath.isEmpty else { return }
        // Segment-sized, not file-sized: the archiver never holds the
        // transcript, so it no longer has to run alone in the shared budget.
        _ = try? await scheduler.run(estimatedBytes: TranscriptArchiver.estimatedPeakBytes) {
            try TranscriptArchiver.archive(
                path: session.filePath,
                into: db.transcriptArchive(provider: provider, session: session)
            )
        }
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
        let revisions: [String: UInt64]
        let pricing: ModelPricing.Snapshot
        let calendar: Calendar
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

    private lazy var rebucketWorker = LatestSnapshotWorker<RebucketSnapshot, RebucketResult>(
        compute: { [aggregateEngine, scheduler] snapshot in
            try await scheduler.run(priority: .interactive) {
                let span = PerformanceTracer.begin("SessionDataStore.rebucket")
                defer { PerformanceTracer.end("SessionDataStore.rebucket", span) }
                let output = try await aggregateEngine.update(.init(
                    stats: snapshot.parsedStats, revisions: snapshot.revisions, sessions: snapshot.sessions,
                    period: snapshot.selectedPeriod, weeklyResetDate: snapshot.weeklyResetDate,
                    allTimeLabel: snapshot.allTimeLabel, pricing: snapshot.pricing, calendar: snapshot.calendar
                ))
                return Self.rebucketResult(output, period: snapshot.selectedPeriod)
            }
        },
        publish: { [weak self] result in self?.applyRebucketResult(result) }
    )

    private func rebucket() {
        needsRebucket = true
        guard isPopoverVisible else { return }
        needsRebucket = false
        let snapshot = RebucketSnapshot(
            parsedStats: parsedStats,
            sessions: sessions,
            selectedPeriod: selectedPeriod,
            weeklyResetDate: weeklyResetDate,
            allTimeLabel: LanguageManager.localizedString("period.all"),
            revisions: statsRevisions,
            pricing: ModelPricing.shared.snapshot(),
            calendar: Calendar.current
        )
        rebucketWorker.submit(snapshot)
    }

    private nonisolated static func rebucketResult(_ output: IncrementalSessionAggregator.Output,
                                                      period: StatsPeriod) -> RebucketResult {
        let visible = Array(output.periods.prefix(period.displayCount))
        return RebucketResult(
            periodStats: output.periods, allTimeCost: output.allTime.totalCost,
            allTimeSessions: output.allTime.sessionCount, allTimeTokens: output.allTime.totalTokens,
            allTimeMessages: output.allTime.messageCount, visibleStats: visible,
            visibleModelBreakdown: computeModelBreakdown(for: visible),
            dailyHeatmap: output.heatmap, availableHeatmapYears: output.years,
            topProjects: output.projects
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
        let currentSessions = sessions
        let provider = self.provider
        let snapshot = parsedStats
        let resetDate = weeklyResetDate
        return (try? await scheduler.run(priority: .interactive) {
            let sourceSessions = currentSessions.isEmpty ? provider.scanSessions() : currentSessions
            try Task.checkCancellation()
            return SessionAllTimeAggregator.periodTopProjects(
                parsedStats: snapshot,
                sessions: sourceSessions,
                period: period,
                periodType: periodType,
                weeklyResetDate: resetDate
            )
        }) ?? []
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

    // Heatmap, top projects and period statistics share the incremental
    // contribution index and land in the same guarded publication.

    // MARK: - Delete

    func deleteSessions(_ ids: Set<String>) {
        let fm = FileManager.default
        for session in sessions where ids.contains(session.id) {
            if !session.isArchived, !session.filePath.isEmpty {
                try? fm.removeItem(atPath: session.filePath)
            }
        }
        sessions.removeAll { ids.contains($0.id) }
        for id in ids {
            quickStats.removeValue(forKey: id)
        }
        var remaining = parsedStats
        for id in ids { remaining.removeValue(forKey: id) }
        publishParsedStats(remaining, changed: ids)
        db.removeSessions(provider: provider.kind, ids)
        rebucket()
    }

    func deleteSession(_ id: String) {
        deleteSessions([id])
    }

    // MARK: - Force rescan

    func forceRescan() {
        dirtySessionIds.removeAll()
        cancelBackgroundWork()
        isFullParseComplete = false
        // Only reset sessions that still have files on disk;
        // archived sessions (no .jsonl) are preserved.
        let liveIds = Set(sessions.filter { !$0.isArchived }.map(\.id))
        db.resetLiveSessions(provider: provider.kind, liveIds: liveIds)
        quickStats.removeAll()
        parsedStats.removeAll()
        initialLoad()
    }

    // MARK: - Transcript Resolution

    /// Writes an archived session's transcript to `url` a stored piece at a
    /// time; see `DatabaseService.writeArchivedTranscript`.
    nonisolated func writeArchivedTranscript(for session: Session, to url: URL) -> Bool {
        db.writeArchivedTranscript(provider: ProviderKind(rawValue: session.provider) ?? .claude,
                                   sessionId: session.id, to: url)
    }

    // MARK: - Helpers

    /// Search messages via FTS without blocking the main thread. A cancelled
    /// caller also cancels its queued work; no detached query outlives the view.
    func searchMessages(query: String) async -> [DatabaseService.SearchResult] {
        let db = self.db
        let kind = self.kind
        return (try? await scheduler.run(priority: .interactive) {
            let signpostState = PerformanceTracer.begin("SessionDataStore.searchMessages")
            defer { PerformanceTracer.end("SessionDataStore.searchMessages", signpostState) }
            return db.search(query: query, provider: kind)
        }) ?? []
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
        return (try? await scheduler.run(priority: .interactive) {
            SessionTrendAggregator.trendData(
                parsedStats: snapshot,
                sessions: snapshotSessions,
                period: period,
                periodType: periodType,
                weeklyResetDate: resetDate
            )
        }) ?? []
    }

    /// Snapshots parsedStats for the given sessions, then computes trend data off the main thread.
    func aggregateProjectTrendData(sessions: [Session], granularity: TrendGranularity = .day) async -> [TrendDataPoint] {
        let snapshot: [SessionStats] = sessions.compactMap { parsedStats[$0.id] }
        return (try? await scheduler.run(priority: .interactive) {
            SessionTrendAggregator.projectTrend(stats: snapshot, granularity: granularity)
        }) ?? []
    }

    /// Aggregates model breakdown for a specific set of sessions.
    func aggregateProjectModelBreakdown(sessions: [Session]) async -> [ModelUsage] {
        // Snapshot on main actor — the per-model fold below is pure but
        // touches `ModelPricing.estimateCost` which is fine off-main.
        let snapshot: [SessionStats] = sessions.compactMap { parsedStats[$0.id] }
        return (try? await scheduler.run(priority: .interactive) {
            SessionTrendAggregator.projectModelBreakdown(stats: snapshot)
        }) ?? []
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
