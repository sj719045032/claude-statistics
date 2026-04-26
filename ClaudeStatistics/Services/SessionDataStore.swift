import Foundation
import ClaudeStatisticsKit
import SwiftUI

@MainActor
final class SessionDataStore: ObservableObject {
    private struct ParseOutcome {
        let sessionId: String
        let committedStats: SessionStats?
        let displayStats: SessionStats?
        let searchMessages: [SearchIndexMessage]
        let shouldRetry: Bool
    }

    // MARK: - Published state (UI binds to these)

    @Published var sessions: [Session] = []
    @Published var quickStats: [String: SessionQuickStats] = [:]
    @Published var parsedStats: [String: SessionStats] = [:]
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
    let provider: any SessionProvider
    private let db = DatabaseService.shared
    private let maxQueuedRetryAttempts = 3
    private let parseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        q.name = "com.claude-statistics.parse"
        return q
    }()

    init(provider: any SessionProvider) {
        self.provider = provider
    }

    // MARK: - Lifecycle

    func start() {
        db.open()

        watcher = provider.makeWatcher { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                self?.handleFileChanges(changedPaths)
            }
        }
        watcher?.start()
        initialLoad()
    }

    func stop() {
        watcher?.stop()
        retryTask?.cancel()
        retryTask = nil
        parseQueue.cancelAllOperations()
        db.close()
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
            let scannedSessions = Self.deduplicatedSessions(provider.scanSessions(), provider: providerKind)
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
                let results = await withTaskGroup(of: ParseOutcome.self) { group in
                    for session in batch {
                        let quick = quickBySessionId[session.id] ?? SessionQuickStats()
                        let cachedSession = cache[session.id]
                        group.addTask {
                            await Self.parseValidatedSession(
                                provider: provider,
                                session: session,
                                quick: quick,
                                cached: cachedSession
                            )
                        }
                    }
                    var batchResults: [ParseOutcome] = []
                    for await result in group {
                        batchResults.append(result)
                    }
                    return batchResults
                }

                // DB write + UI update (serial)
                let sessionsById = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
                for result in results {
                    guard let stats = result.committedStats else { continue }
                    guard let session = sessionsById[result.sessionId] else { continue }
                    db.saveSessionStatsAndIndex(
                        provider: providerKind,
                        sessionId: session.id,
                        fileSize: session.fileSize,
                        mtime: session.lastModified,
                        stats: stats,
                        searchMessages: result.searchMessages
                    )
                }
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
                scannedSessions = Self.deduplicatedSessions(provider.scanSessions(), provider: providerKind)
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

            for (i, session) in dirtySessions.enumerated() {
                let quick = provider.parseQuickStats(at: session.filePath)
                db.saveQuickStats(provider: providerKind, sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, stats: quick)
                await MainActor.run { self.quickStats[session.id] = quick }

                let outcome = await Self.parseValidatedSession(
                    provider: provider,
                    session: session,
                    quick: quick,
                    cached: cache[session.id]
                )
                if let stats = outcome.committedStats {
                    db.saveSessionStatsAndIndex(
                        provider: providerKind,
                        sessionId: session.id,
                        fileSize: session.fileSize,
                        mtime: session.lastModified,
                        stats: stats,
                        searchMessages: outcome.searchMessages
                    )
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

    nonisolated private static func parseValidatedSession(
        provider: any SessionProvider,
        session: Session,
        quick: SessionQuickStats,
        cached: DatabaseService.CachedSession?
    ) async -> ParseOutcome {
        let firstStats = provider.parseSession(at: session.filePath)
        if suspiciousParseReason(stats: firstStats, quick: quick, session: session) == nil {
            let searchMessages = provider.parseSearchIndexMessages(at: session.filePath)
            return ParseOutcome(
                sessionId: session.id,
                committedStats: firstStats,
                displayStats: firstStats,
                searchMessages: searchMessages,
                shouldRetry: false
            )
        }

        let firstReason = suspiciousParseReason(stats: firstStats, quick: quick, session: session) ?? "suspicious parse result"
        DiagnosticLogger.shared.warning("Suspicious \(provider.kind.rawValue) parse for \(session.id); retrying once (\(firstReason))")
        try? await Task.sleep(nanoseconds: 300_000_000)

        let retryStats = provider.parseSession(at: session.filePath)
        if suspiciousParseReason(stats: retryStats, quick: quick, session: session) == nil {
            let searchMessages = provider.parseSearchIndexMessages(at: session.filePath)
            DiagnosticLogger.shared.info("Recovered \(provider.kind.rawValue) parse for \(session.id) after retry")
            return ParseOutcome(
                sessionId: session.id,
                committedStats: retryStats,
                displayStats: retryStats,
                searchMessages: searchMessages,
                shouldRetry: false
            )
        }

        let retryReason = suspiciousParseReason(stats: retryStats, quick: quick, session: session) ?? firstReason
        DiagnosticLogger.shared.warning("Rejected \(provider.kind.rawValue) parse for \(session.id); keeping last committed cache (\(retryReason))")
        return ParseOutcome(
            sessionId: session.id,
            committedStats: nil,
            displayStats: cached?.sessionStats,
            searchMessages: [],
            shouldRetry: true
        )
    }

    nonisolated private static func suspiciousParseReason(
        stats: SessionStats,
        quick: SessionQuickStats,
        session: Session
    ) -> String? {
        if let start = stats.startTime, let end = stats.endTime, end < start {
            return "endTime earlier than startTime"
        }
        if quick.messageCount > 0 && stats.messageCount == 0 {
            return "quick messages=\(quick.messageCount), full messages=0"
        }
        if quick.userMessageCount > 0 && stats.userMessageCount == 0 {
            return "quick user messages=\(quick.userMessageCount), full user messages=0"
        }
        if quick.totalTokens > 0 && stats.totalTokens == 0 {
            return "quick tokens=\(quick.totalTokens), full tokens=0"
        }
        let sessionLooksNonEmpty = quick.startTime != nil || quick.messageCount > 0 || quick.totalTokens > 0
        if session.fileSize >= 4_096 &&
            sessionLooksNonEmpty &&
            stats.startTime == nil &&
            stats.endTime == nil &&
            stats.messageCount == 0 &&
            stats.totalTokens == 0 {
            return "empty full stats for non-empty session"
        }
        if stats.messageCount == 0 && (stats.userMessageCount > 0 || stats.assistantMessageCount > 0) {
            return "message counters exist without time slices"
        }
        return nil
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

        for session in sessions {
            guard let cached = cache[session.id],
                  let stats = cached.sessionStats else { continue }
            let searchMessages = provider.parseSearchIndexMessages(at: session.filePath)
            db.saveSessionStatsAndIndex(
                provider: provider.kind,
                sessionId: session.id,
                fileSize: session.fileSize,
                mtime: session.lastModified,
                stats: stats,
                searchMessages: searchMessages
            )
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

    nonisolated private static func deduplicatedSessions(
        _ sessions: [Session],
        provider: ProviderKind
    ) -> [Session] {
        guard !sessions.isEmpty else { return [] }

        var bestById: [String: Session] = [:]
        var duplicateCounts: [String: Int] = [:]

        for session in sessions {
            if let existing = bestById[session.id] {
                duplicateCounts[session.id, default: 1] += 1
                if shouldReplace(existing: existing, with: session) {
                    bestById[session.id] = session
                }
            } else {
                bestById[session.id] = session
            }
        }

        if !duplicateCounts.isEmpty {
            let sample = duplicateCounts
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }
                .prefix(5)
                .map { "\($0.key)(x\($0.value))" }
                .joined(separator: ", ")
            DiagnosticLogger.shared.warning(
                "Deduplicated \(provider.rawValue) sessions by id: dropped \(sessions.count - bestById.count) duplicates; sample: \(sample)"
            )
        }

        return bestById.values.sorted { $0.lastModified > $1.lastModified }
    }

    nonisolated private static func shouldReplace(existing: Session, with candidate: Session) -> Bool {
        if candidate.lastModified != existing.lastModified {
            return candidate.lastModified > existing.lastModified
        }
        if candidate.fileSize != existing.fileSize {
            return candidate.fileSize > existing.fileSize
        }
        return candidate.filePath > existing.filePath
    }

    // MARK: - Rebucket

    private func rebucket() {
        guard !parsedStats.isEmpty else { return }

        // All-time scope: produce a single aggregated PeriodStats spanning all data
        if selectedPeriod == .all {
            rebucketAllTime()
            return
        }

        var buckets: [Date: PeriodStats] = [:]
        var periodSessionIds: [Date: Set<String>] = [:]
        var periodModelSessionIds: [Date: [String: Set<String>]] = [:]

        let resetDate = weeklyResetDate
        // Use fiveMinSlices when weekly period has non-midnight boundary for accurate attribution
        let useFineSlices = selectedPeriod == .weekly && resetDate != nil

        for (sessionId, stats) in parsedStats {
            let slices = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            if !slices.isEmpty {
                for (sliceStart, slice) in slices {
                    let periodStart = selectedPeriod.startOfPeriod(for: sliceStart, weeklyResetDate: resetDate)
                    if buckets[periodStart] == nil {
                        buckets[periodStart] = PeriodStats(
                            period: periodStart,
                            periodLabel: selectedPeriod.label(for: periodStart, weeklyResetDate: resetDate),
                            chartLabel: selectedPeriod.chartLabel(for: periodStart, weeklyResetDate: resetDate)
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
                let session = sessions.first { $0.id == sessionId }
                let date = stats.startTime ?? session?.lastModified ?? Date.distantPast
                let periodStart = selectedPeriod.startOfPeriod(for: date, weeklyResetDate: resetDate)
                if buckets[periodStart] == nil {
                    buckets[periodStart] = PeriodStats(
                        period: periodStart,
                        periodLabel: selectedPeriod.label(for: periodStart, weeklyResetDate: resetDate),
                        chartLabel: selectedPeriod.chartLabel(for: periodStart, weeklyResetDate: resetDate)
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

        periodStats = buckets.values.sorted { $0.period > $1.period }

        // Update cached aggregates
        allTimeCost = parsedStats.values.reduce(0) { $0 + $1.estimatedCost }
        allTimeSessions = parsedStats.count
        allTimeTokens = parsedStats.values.reduce(0) { $0 + $1.totalTokens }
        allTimeMessages = parsedStats.values.reduce(0) { $0 + $1.messageCount }
        visibleStats = Array(periodStats.prefix(selectedPeriod.displayCount))
        visibleModelBreakdown = modelBreakdown(for: visibleStats)
        recomputeAllTimeAggregates()
    }

    /// Aggregate every session into a single "All Time" PeriodStats.
    /// Matches the shape produced by `rebucket()` so downstream views (PeriodDetailView-like)
    /// can consume it without branching on scope.
    ///
    /// `period.period` is intentionally set to `Date.distantPast` to line up with
    /// `StatsPeriod.all.startOfPeriod(for:)` — `aggregateTrendData` compares the two
    /// for equality when deciding which slices to include.
    private func rebucketAllTime() {
        let label = LanguageManager.localizedString("period.all")
        var agg = PeriodStats(period: Date.distantPast, periodLabel: label, chartLabel: label)
        var modelSessionIds: [String: Set<String>] = [:]

        // Accumulate every five-minute slice from every session; fall back to session-level
        // aggregation when a session has no slices (older cached data).
        for (sessionId, stats) in parsedStats {
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
        agg.sessionCount = parsedStats.count
        for (model, ids) in modelSessionIds {
            if var usage = agg.modelBreakdown[model] {
                usage.sessionCount = ids.count
                agg.modelBreakdown[model] = usage
            }
        }

        periodStats = [agg]

        // Cached aggregates — derivable from agg directly
        allTimeCost = agg.totalCost
        allTimeSessions = agg.sessionCount
        allTimeTokens = agg.totalTokens
        allTimeMessages = agg.messageCount
        visibleStats = [agg]
        visibleModelBreakdown = modelBreakdown(for: [agg])
        recomputeAllTimeAggregates()
    }

    // MARK: - Top projects (all-time aggregation by project path)

    /// Aggregate projects by their `cwd` (or projectPath fallback) for a specific period.
    /// Aggregate projects by their `cwd` (or projectPath fallback) for a specific period.
    func aggregatePeriodTopProjects(for period: PeriodStats, periodType: StatsPeriod) async -> [TopProject] {
        // Snapshot main-actor state so the heavy fold runs off the UI thread.
        let currentSessions = sessions.isEmpty ? ProviderRegistry.provider(for: provider.kind).scanSessions() : sessions
        let snapshot = parsedStats
        let resetDate = weeklyResetDate
        return await Task.detached {
            Self.computePeriodTopProjects(
                parsedStats: snapshot,
                sessions: currentSessions,
                period: period,
                periodType: periodType,
                weeklyResetDate: resetDate
            )
        }.value
    }

    private nonisolated static func computePeriodTopProjects(
        parsedStats: [String: SessionStats],
        sessions: [Session],
        period: PeriodStats,
        periodType: StatsPeriod,
        weeklyResetDate: Date?
    ) -> [TopProject] {
        struct Acc {
            var cost: Double = 0
            var tokens: Int = 0
            var sessionCount: Int = 0
            var messageCount: Int = 0
        }
        var acc: [String: Acc] = [:]
        let sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        let periodStart = period.period
        let periodEnd = periodType == .all ? Date.distantFuture : periodType.nextPeriodStart(after: periodStart, weeklyResetDate: weeklyResetDate)

        for (sessionId, stats) in parsedStats {
            guard let session = sessionById[sessionId] else { continue }
            let key = session.cwd ?? session.projectPath

            let sStart = stats.startTime ?? session.lastModified
            let sEnd = stats.endTime ?? session.lastModified

            // Check if session interval [sStart, sEnd] overlaps with [periodStart, periodEnd)
            let overlaps = sStart < periodEnd && sEnd >= periodStart
            guard overlaps else { continue }

            var a = acc[key, default: Acc()]

            if stats.fiveMinSlices.isEmpty {
                // For all-time aggregated stats (Date.distantPast), or if start periods match
                if periodType == .all || periodType.startOfPeriod(for: sStart, weeklyResetDate: weeklyResetDate) == periodStart {
                    a.cost += stats.estimatedCost
                    a.tokens += stats.totalTokens
                    a.messageCount += stats.messageCount
                    a.sessionCount += 1
                }
            } else {
                var costInPeriod = 0.0
                var tokensInPeriod = 0
                var messagesInPeriod = 0
                var hasActivityInPeriod = false

                for (sliceTime, slice) in stats.fiveMinSlices {
                    if sliceTime >= periodStart && sliceTime < periodEnd {
                        costInPeriod += slice.estimatedCost
                        tokensInPeriod += slice.totalTokens
                        messagesInPeriod += slice.messageCount
                        hasActivityInPeriod = true
                    }
                }

                if hasActivityInPeriod {
                    a.cost += costInPeriod
                    a.tokens += tokensInPeriod
                    a.messageCount += messagesInPeriod
                    a.sessionCount += 1
                } else if periodType == .all {
                    // Fallback for .all when slices exist but for some reason aren't matching
                    a.cost += stats.estimatedCost
                    a.tokens += stats.totalTokens
                    a.messageCount += stats.messageCount
                    a.sessionCount += 1
                }
            }
            acc[key] = a
        }

        return acc.map { key, v in
            TopProject(
                path: key,
                displayName: Self.displayNameForProjectPath(key),
                cost: v.cost,
                tokens: v.tokens,
                sessionCount: v.sessionCount,
                messageCount: v.messageCount
            )
        }.filter { $0.sessionCount > 0 }.sorted { $0.cost > $1.cost }
    }

    /// Aggregate all sessions by their `cwd` (or projectPath fallback), sorted by estimated cost desc.
    /// Used by the All-Time view's "Top Projects" card.
    ///
    /// Now backed by `_topProjectsCache` populated in `rebucket()` /
    /// `rebucketAllTime()`. Was a O(sessions × slices) computed property —
    /// AllTimeView read it from `body` so each SwiftUI re-render walked
    /// every session's full slice map, dominating CPU when entering the
    /// statistics page.
    var topProjects: [TopProject] { _topProjectsCache }
    @Published private var _topProjectsCache: [TopProject] = []

    /// Trim/relabel a full path into something compact enough for a list row.
    /// Prefers the last path component (like the basename of a repo).
    nonisolated private static func displayNameForProjectPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let last = (expanded as NSString).lastPathComponent
        return last.isEmpty ? expanded : last
    }

    // MARK: - Daily activity heatmap data

    /// Per-day aggregated cost + tokens for the heatmap in the All-Time view.
    /// Key is `startOfDay` in the user's local timezone.
    ///
    /// Now backed by `_dailyHeatmapCache` populated in `rebucket()` /
    /// `rebucketAllTime()`. Was a O(sessions × slices) computed property —
    /// AllTimeView read it from `body` *twice* per render so each redraw
    /// walked every session's full slice map twice.
    var dailyHeatmapData: [Date: DailyHeatmapBucket] { _dailyHeatmapCache }
    @Published private var _dailyHeatmapCache: [Date: DailyHeatmapBucket] = [:]

    /// Sorted-descending list of calendar years present in `dailyHeatmapData`.
    /// Cached alongside the heatmap so AllTimeView's scope picker doesn't
    /// re-run a `Set` build + `sort` over every dictionary key on each body
    /// pass.
    var availableHeatmapYears: [Int] { _availableHeatmapYearsCache }
    @Published private var _availableHeatmapYearsCache: [Int] = []

    /// Recompute `_dailyHeatmapCache` and `_topProjectsCache`. Single
    /// O(sessions × slices) walk producing both — the heatmap's daily
    /// buckets are derived in the same loop as the top-projects per-cwd
    /// accumulator, so we do one pass instead of two.
    fileprivate func recomputeAllTimeAggregates() {
        let cal = Calendar.current
        var heatmap: [Date: DailyHeatmapBucket] = [:]

        struct ProjectAcc {
            var cost: Double = 0
            var tokens: Int = 0
            var sessionCount: Int = 0
            var messageCount: Int = 0
        }
        var projectAcc: [String: ProjectAcc] = [:]
        let sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        for (sessionId, stats) in parsedStats {
            // Heatmap bucket
            for (sliceTime, slice) in stats.fiveMinSlices {
                let day = cal.startOfDay(for: sliceTime)
                var b = heatmap[day, default: DailyHeatmapBucket(date: day, cost: 0, tokens: 0)]
                b.cost += slice.estimatedCost
                b.tokens += slice.totalTokens
                heatmap[day] = b
            }

            // Top-projects accumulator
            guard let session = sessionById[sessionId] else { continue }
            let key = session.cwd ?? session.projectPath
            var a = projectAcc[key, default: ProjectAcc()]
            if stats.fiveMinSlices.isEmpty {
                a.cost += stats.estimatedCost
                a.tokens += stats.totalTokens
                a.messageCount += stats.messageCount
                a.sessionCount += 1
            } else {
                var costInPeriod = 0.0
                var tokensInPeriod = 0
                var messagesInPeriod = 0
                for (_, slice) in stats.fiveMinSlices {
                    costInPeriod += slice.estimatedCost
                    tokensInPeriod += slice.totalTokens
                    messagesInPeriod += slice.messageCount
                }
                a.cost += costInPeriod
                a.tokens += tokensInPeriod
                a.messageCount += messagesInPeriod
                a.sessionCount += 1
            }
            projectAcc[key] = a
        }

        _dailyHeatmapCache = heatmap
        let years = Set(heatmap.keys.map { cal.component(.year, from: $0) })
        _availableHeatmapYearsCache = years.sorted(by: >)
        _topProjectsCache = projectAcc.map { key, v in
            TopProject(
                path: key,
                displayName: Self.displayNameForProjectPath(key),
                cost: v.cost,
                tokens: v.tokens,
                sessionCount: v.sessionCount,
                messageCount: v.messageCount
            )
        }.filter { $0.sessionCount > 0 }.sorted { $0.cost > $1.cost }
    }

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

    /// Search messages via FTS index
    func searchMessages(query: String) -> [DatabaseService.SearchResult] {
        db.search(query: query, provider: provider.kind)
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
            Self.computeTrendData(
                parsedStats: snapshot,
                sessions: snapshotSessions,
                period: period,
                periodType: periodType,
                weeklyResetDate: resetDate
            )
        }.value
    }

    private nonisolated static func computeTrendData(
        parsedStats: [String: SessionStats],
        sessions: [Session],
        period: PeriodStats,
        periodType: StatsPeriod,
        weeklyResetDate: Date?
    ) -> [TrendDataPoint] {
        let granularity = periodType.trendGranularity
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        // Use fiveMinSlices for daily view or weekly with non-midnight subscription boundary
        let useFineSlices = periodType == .daily || (periodType == .weekly && weeklyResetDate != nil)

        let sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        for (sessionId, stats) in parsedStats {
            let slices: [Date: DaySlice] = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            if !slices.isEmpty {
                for (sliceTime, slice) in slices {
                    let slicePeriodStart = periodType.startOfPeriod(for: sliceTime, weeklyResetDate: weeklyResetDate)
                    guard slicePeriodStart == period.period else { continue }

                    let bucket = granularity.bucketStart(for: sliceTime)
                    var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
                    existing.tokens += slice.totalTokens
                    existing.cost += slice.estimatedCost
                    buckets[bucket] = existing
                }
            } else {
                // Fallback for sessions without hourSlice data
                guard let session = sessionById[sessionId] else { continue }
                let sessionDate = stats.startTime ?? session.lastModified
                let sessionPeriodStart = periodType.startOfPeriod(for: sessionDate, weeklyResetDate: weeklyResetDate)
                guard sessionPeriodStart == period.period else { continue }

                let bucket = granularity.bucketStart(for: sessionDate)
                var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
                existing.tokens += stats.totalTokens
                existing.cost += stats.estimatedCost
                buckets[bucket] = existing
            }
        }

        // Sort by time, then accumulate into running totals
        let sorted = buckets.sorted { $0.key < $1.key }
        let cal = Calendar.current
        var result: [TrendDataPoint] = []

        // Zero-origin baseline. For bounded periods (daily/weekly/monthly), `period.period`
        // is the exact start-of-period. For `.all`, `period.period` is `distantPast` which
        // would blow up the X-axis, so pin the baseline to the first bucket instead.
        if !sorted.isEmpty {
            let origin: Date = (periodType == .all) ? sorted.first!.key : period.period
            result.append(TrendDataPoint(time: origin, tokens: 0, cost: 0))
        }

        // Data points at the END of each bucket (cumulative up to that point)
        var cumTokens = 0
        var cumCost = 0.0
        for (i, (time, val)) in sorted.enumerated() {
            cumTokens += val.tokens
            cumCost += val.cost
            // End of bucket = start of next granularity unit
            // For the last bucket, cap at "now" to avoid showing future time
            let bucketEnd = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: time)!
            let dataTime = (i == sorted.count - 1) ? min(bucketEnd, Date()) : bucketEnd
            result.append(TrendDataPoint(time: dataTime, tokens: cumTokens, cost: cumCost))
        }
        return result
    }

    /// Aggregate raw token/cost usage for a rolling time window.
    func aggregateWindowTrendData(from start: Date, to end: Date, granularity: TrendGranularity, cumulative: Bool = false, modelFilter: ((String) -> Bool)? = nil) -> [TrendDataPoint] {
        guard start < end else { return [] }

        let cal = Calendar.current
        let useFineSlices = granularity == .fiveMinute || granularity == .minute || granularity == .hour
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        for stats in parsedStats.values {
            let slices: [Date: DaySlice] = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            for (sliceTime, slice) in slices {
                // Exclusive start: data at exact boundary belongs to previous period
                guard sliceTime > start, sliceTime < end else { continue }

                let bucket = granularity.bucketStart(for: sliceTime)
                var existing = buckets[bucket, default: (tokens: 0, cost: 0)]

                if let filter = modelFilter {
                    for (model, modelStats) in slice.modelBreakdown where filter(model) {
                        existing.tokens += modelStats.totalTokens
                        existing.cost += ModelPricing.estimateCost(
                            model: model,
                            inputTokens: modelStats.inputTokens,
                            outputTokens: modelStats.outputTokens,
                            cacheCreation5mTokens: modelStats.cacheCreation5mTokens,
                            cacheCreation1hTokens: modelStats.cacheCreation1hTokens,
                            cacheCreationTotalTokens: modelStats.cacheCreationTotalTokens,
                            cacheReadTokens: modelStats.cacheReadTokens
                        )
                    }
                } else {
                    existing.tokens += slice.totalTokens
                    existing.cost += slice.estimatedCost
                }
                buckets[bucket] = existing
            }
        }

        if cumulative {
            var result: [TrendDataPoint] = [TrendDataPoint(time: start, tokens: 0, cost: 0)]
            var bucketTime = granularity.bucketStart(for: start)
            var cumTokens = 0
            var cumCost = 0.0

            while bucketTime < end {
                let bucket = buckets[bucketTime, default: (tokens: 0, cost: 0)]
                cumTokens += bucket.tokens
                cumCost += bucket.cost
                // Only add points after the zero-origin to keep x-axis monotonic
                if bucketTime > start {
                    result.append(TrendDataPoint(time: bucketTime, tokens: cumTokens, cost: cumCost))
                }
                guard let nextBucket = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: bucketTime) else { break }
                bucketTime = nextBucket
            }

            // Data from the first or current partial bucket was accumulated but not yet plotted 
            // if the loop ended before the next boundary. Append it at the exact end time.
            if result.last?.time != end {
                result.append(TrendDataPoint(time: end, tokens: cumTokens, cost: cumCost))
            }

            return result
        }

        // Non-cumulative: per-bucket values
        var result: [TrendDataPoint] = []
        var bucketTime = granularity.bucketStart(for: start)

        while bucketTime < end {
            let bucket = buckets[bucketTime, default: (tokens: 0, cost: 0)]
            result.append(TrendDataPoint(time: bucketTime, tokens: bucket.tokens, cost: bucket.cost))
            guard let nextBucket = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: bucketTime) else { break }
            bucketTime = nextBucket
        }

        return result
    }

    /// Snapshots parsedStats for the given sessions, then computes trend data off the main thread.
    func aggregateProjectTrendData(sessions: [Session], granularity: TrendGranularity = .day) async -> [TrendDataPoint] {
        // Snapshot on main actor
        let snapshot: [SessionStats] = sessions.compactMap { parsedStats[$0.id] }
        // Compute off main thread
        return await Task.detached {
            Self.computeProjectTrend(stats: snapshot, granularity: granularity)
        }.value
    }

    private nonisolated static func computeProjectTrend(stats: [SessionStats], granularity: TrendGranularity) -> [TrendDataPoint] {
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]
        let cal = Calendar.current

        for stat in stats {
            for (time, slice) in stat.fiveMinSlices {
                let bucket = granularity.bucketStart(for: time)
                var existing = buckets[bucket, default: (tokens: 0, cost: 0.0)]
                existing.tokens += slice.totalTokens
                existing.cost += slice.estimatedCost
                buckets[bucket] = existing
            }
        }

        let sorted = buckets.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return [] }

        var result: [TrendDataPoint] = [TrendDataPoint(time: sorted.first!.key, tokens: 0, cost: 0)]
        var cumTokens = 0
        var cumCost = 0.0
        for (i, (time, val)) in sorted.enumerated() {
            cumTokens += val.tokens
            cumCost += val.cost
            let bucketEnd = cal.date(byAdding: granularity.calendarComponent, value: granularity.stepValue, to: time)!
            let dataTime = (i == sorted.count - 1) ? min(bucketEnd, Date()) : bucketEnd
            result.append(TrendDataPoint(time: dataTime, tokens: cumTokens, cost: cumCost))
        }
        return result
    }

    /// Aggregates model breakdown for a specific set of sessions.
    func aggregateProjectModelBreakdown(sessions: [Session]) async -> [ModelUsage] {
        // Snapshot on main actor — the per-model fold below is pure but
        // touches `ModelPricing.estimateCost` which is fine off-main.
        let snapshot: [SessionStats] = sessions.compactMap { parsedStats[$0.id] }
        return await Task.detached {
            Self.computeProjectModelBreakdown(stats: snapshot)
        }.value
    }

    private nonisolated static func computeProjectModelBreakdown(stats: [SessionStats]) -> [ModelUsage] {
        var combined: [String: ModelUsage] = [:]
        for st in stats {
            for (model, mts) in st.modelBreakdown {
                var usage = combined[model] ?? ModelUsage(model: model)
                usage.inputTokens += mts.inputTokens
                usage.outputTokens += mts.outputTokens
                usage.cacheCreation5mTokens += mts.cacheCreation5mTokens
                usage.cacheCreation1hTokens += mts.cacheCreation1hTokens
                usage.cacheCreationTotalTokens += mts.cacheCreationTotalTokens
                usage.cacheReadTokens += mts.cacheReadTokens
                usage.cost += ModelPricing.estimateCost(
                    model: model,
                    inputTokens: mts.inputTokens,
                    outputTokens: mts.outputTokens,
                    cacheCreation5mTokens: mts.cacheCreation5mTokens,
                    cacheCreation1hTokens: mts.cacheCreation1hTokens,
                    cacheCreationTotalTokens: mts.cacheCreationTotalTokens,
                    cacheReadTokens: mts.cacheReadTokens
                )
                usage.messageCount += mts.messageCount
                usage.sessionCount += 1
                combined[model] = usage
            }
        }
        return combined.values.sorted { $0.cost > $1.cost }
    }

    func windowModelBreakdown(from start: Date, to end: Date, modelFilter: ((String) -> Bool)? = nil) -> [ModelUsage] {
        guard start < end else { return [] }

        var combined: [String: ModelUsage] = [:]
        var modelSessionIds: [String: Set<String>] = [:]

        for (sessionId, stats) in parsedStats {
            for (sliceTime, slice) in stats.fiveMinSlices {
                // Exclusive start: data at exact boundary belongs to previous period
                guard sliceTime > start, sliceTime < end else { continue }

                for (model, modelStats) in slice.modelBreakdown {
                    if let filter = modelFilter, !filter(model) { continue }
                    var existing = combined[model] ?? ModelUsage(model: model)
                    existing.inputTokens += modelStats.inputTokens
                    existing.outputTokens += modelStats.outputTokens
                    existing.cacheCreation5mTokens += modelStats.cacheCreation5mTokens
                    existing.cacheCreation1hTokens += modelStats.cacheCreation1hTokens
                    existing.cacheCreationTotalTokens += modelStats.cacheCreationTotalTokens
                    existing.cacheReadTokens += modelStats.cacheReadTokens
                    existing.cost += ModelPricing.estimateCost(
                        model: model,
                        inputTokens: modelStats.inputTokens,
                        outputTokens: modelStats.outputTokens,
                        cacheCreation5mTokens: modelStats.cacheCreation5mTokens,
                        cacheCreation1hTokens: modelStats.cacheCreation1hTokens,
                        cacheCreationTotalTokens: modelStats.cacheCreationTotalTokens,
                        cacheReadTokens: modelStats.cacheReadTokens
                    )
                    existing.messageCount += modelStats.messageCount
                    combined[model] = existing
                    modelSessionIds[model, default: []].insert(sessionId)
                }
            }
        }

        for (model, ids) in modelSessionIds {
            if var usage = combined[model] {
                usage.sessionCount = ids.count
                combined[model] = usage
            }
        }

        return combined.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    var globalModelBreakdown: [ModelUsage] {
        modelBreakdown(for: periodStats)
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
        return ShareRoleEngine.makeRoleResult(metrics: metrics, baseline: baseline)
    }

    func buildAllTimeShareRoleResult() -> ShareRoleResult? {
        guard let metrics = buildAllTimeShareMetrics(
            scopeLabel: LanguageManager.localizedString("share.scope.allTime")
        ) else {
            return nil
        }
        let baseline = buildAllTimeShareBaselineMetrics()
        return ShareRoleEngine.makeAllTimeRoleResult(metrics: metrics, baseline: baseline)
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

    private func modelBreakdown(for periods: [PeriodStats]) -> [ModelUsage] {
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
}

// MARK: - All-Time helper types

struct TopProject: Identifiable, Hashable {
    let path: String
    let displayName: String
    let cost: Double
    let tokens: Int
    let sessionCount: Int
    let messageCount: Int

    var id: String { path }
}

struct DailyHeatmapBucket: Hashable {
    let date: Date
    var cost: Double
    var tokens: Int
}
