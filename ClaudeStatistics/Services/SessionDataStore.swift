import Foundation
import SwiftUI

@MainActor
final class SessionDataStore: ObservableObject {
    // MARK: - Published state (UI binds to these)

    @Published var sessions: [Session] = []
    @Published var quickStats: [String: TranscriptParser.QuickStats] = [:]
    @Published var parsedStats: [String: SessionStats] = [:]
    @Published var selectedPeriod: StatsPeriod = .daily { didSet { rebucket() } }
    @Published var periodStats: [PeriodStats] = []
    @Published var isFullParseComplete = false
    @Published var parseProgress: String?

    // MARK: - Internal state

    private var dirtySessionIds: Set<String> = []
    private var isPopoverVisible = false
    private var watcher: FSEventsWatcher?
    private let db = DatabaseService.shared
    private let parseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        q.name = "com.claude-statistics.parse"
        return q
    }()

    // MARK: - Lifecycle

    func start() {
        db.open()

        let projectsDir = (CredentialService.shared.claudeConfigDir() as NSString).appendingPathComponent("projects")
        watcher = FSEventsWatcher(path: projectsDir, debounceSeconds: 2.0) { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                self?.handleFileChanges(changedPaths)
            }
        }
        watcher?.start()
        initialLoad()
    }

    func stop() {
        watcher?.stop()
        parseQueue.cancelAllOperations()
        db.close()
    }

    // MARK: - Popover visibility

    func popoverDidOpen() {
        isPopoverVisible = true
        if !dirtySessionIds.isEmpty {
            refreshDirtySessions()
        }
    }

    func popoverDidClose() {
        isPopoverVisible = false
    }

    // MARK: - Initial load

    private func initialLoad() {
        parseProgress = "Scanning sessions..."

        Task.detached { [weak self] in
            guard let self else { return }
            let db = self.db
            let scannedSessions = SessionScanner.shared.scanSessions()
            DiagnosticLogger.shared.appLaunched(sessionCount: scannedSessions.count)

            // Load DB cache and determine which sessions need reparsing
            let cache = db.loadAllCached()
            var dirtyIds: [Session] = []
            var quickMap: [String: TranscriptParser.QuickStats] = [:]
            var statsMap: [String: SessionStats] = [:]

            for session in scannedSessions {
                if db.needsReparse(sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, cache: cache) {
                    dirtyIds.append(session)
                } else if let cached = cache[session.id] {
                    if let q = cached.quickStats { quickMap[session.id] = q }
                    if let s = cached.sessionStats { statsMap[session.id] = s }
                }
            }

            await MainActor.run {
                self.sessions = scannedSessions
                self.quickStats = quickMap
                self.parsedStats = statsMap
                if !statsMap.isEmpty { self.rebucket() }
                self.parseProgress = dirtyIds.isEmpty ? nil : "Loading..."
            }

            if dirtyIds.isEmpty {
                // Clean up DB entries for deleted sessions
                let currentIds = Set(scannedSessions.map(\.id))
                let staleIds = Set(cache.keys).subtracting(currentIds)
                if !staleIds.isEmpty { db.removeSessions(staleIds) }

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
            for session in dirtyIds {
                let quick = TranscriptParser.shared.parseSessionQuick(at: session.filePath)
                db.saveQuickStats(sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, stats: quick)
                await MainActor.run {
                    self.quickStats[session.id] = quick
                }
            }

            // Full parse + index dirty sessions
            let total = dirtyIds.count
            for (i, session) in dirtyIds.enumerated() {
                let stats = TranscriptParser.shared.parseSession(at: session.filePath)
                db.saveSessionStats(sessionId: session.id, stats: stats)
                db.indexSession(sessionId: session.id, filePath: session.filePath)

                await MainActor.run {
                    self.parsedStats[session.id] = stats
                    if (i + 1) % 20 == 0 || i == total - 1 {
                        self.parseProgress = "Parsing \(i + 1)/\(total)..."
                        self.rebucket()
                    }
                }
            }

            // Clean up DB entries for deleted sessions
            let currentIds = Set(scannedSessions.map(\.id))
            let staleIds = Set(cache.keys).subtracting(currentIds)
            if !staleIds.isEmpty { db.removeSessions(staleIds) }

            await MainActor.run {
                self.rebucket()
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
        }
    }

    // MARK: - File change handling

    private func handleFileChanges(_ changedPaths: Set<String>) {
        var changedIds: Set<String> = []

        for path in changedPaths {
            let fileName = (path as NSString).lastPathComponent
            guard fileName.hasSuffix(".jsonl") else { continue }
            changedIds.insert((fileName as NSString).deletingPathExtension)
        }

        guard !changedIds.isEmpty else { return }

        if isPopoverVisible {
            processDirtyIds(changedIds)
        } else {
            dirtySessionIds.formUnion(changedIds)
        }
    }

    // MARK: - Dirty session processing

    private func refreshDirtySessions() {
        let ids = dirtySessionIds
        dirtySessionIds.removeAll()
        processDirtyIds(ids)
    }

    private func processDirtyIds(_ ids: Set<String>) {
        Task.detached { [weak self] in
            guard let self else { return }
            let db = self.db

            // Rescan to pick up new/deleted files
            let scannedSessions = SessionScanner.shared.scanSessions()

            await MainActor.run {
                self.sessions = scannedSessions
                self.cleanupDeletedSessions(current: scannedSessions)
            }

            let dirtySessions = scannedSessions.filter { ids.contains($0.id) }

            // Quick-parse + full-parse + index changed sessions
            for session in dirtySessions {
                let quick = TranscriptParser.shared.parseSessionQuick(at: session.filePath)
                db.saveQuickStats(sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, stats: quick)
                await MainActor.run { self.quickStats[session.id] = quick }

                let stats = TranscriptParser.shared.parseSession(at: session.filePath)
                db.saveSessionStats(sessionId: session.id, stats: stats)
                db.indexSession(sessionId: session.id, filePath: session.filePath)
                await MainActor.run { self.parsedStats[session.id] = stats }
            }

            await MainActor.run { self.rebucket() }
        }
    }

    // MARK: - Rebucket

    private func rebucket() {
        guard !parsedStats.isEmpty else { return }

        var buckets: [Date: PeriodStats] = [:]
        var periodSessionIds: [Date: Set<String>] = [:]

        for (sessionId, stats) in parsedStats {
            if !stats.daySlices.isEmpty {
                // Use per-day data for accurate period attribution
                for (dayStart, slice) in stats.daySlices {
                    let periodStart = selectedPeriod.startOfPeriod(for: dayStart)
                    if buckets[periodStart] == nil {
                        buckets[periodStart] = PeriodStats(
                            period: periodStart,
                            periodLabel: selectedPeriod.label(for: periodStart)
                        )
                    }
                    buckets[periodStart]?.accumulate(daySlice: slice)
                    periodSessionIds[periodStart, default: []].insert(sessionId)
                }
            } else {
                // Fallback for sessions without day slices
                let session = sessions.first { $0.id == sessionId }
                let date = stats.startTime ?? session?.lastModified ?? Date.distantPast
                let periodStart = selectedPeriod.startOfPeriod(for: date)
                if buckets[periodStart] == nil {
                    buckets[periodStart] = PeriodStats(
                        period: periodStart,
                        periodLabel: selectedPeriod.label(for: periodStart)
                    )
                }
                buckets[periodStart]?.accumulate(stats: stats)
                periodSessionIds[periodStart, default: []].insert(sessionId)
            }
        }

        // Set accurate session counts (one session counted once per period)
        for (period, ids) in periodSessionIds {
            buckets[period]?.sessionCount = ids.count
        }

        periodStats = buckets.values.sorted { $0.period > $1.period }
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
        db.removeSessions(ids)
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
        db.resetDatabase()
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
        db.removeSessions(staleIds)
    }

    /// Search messages via FTS index
    func searchMessages(query: String) -> [DatabaseService.SearchResult] {
        db.search(query: query)
    }

    // MARK: - Computed (convenience for views)

    var allTimeCost: Double {
        periodStats.reduce(0) { $0 + $1.totalCost }
    }

    var allTimeSessions: Int {
        periodStats.reduce(0) { $0 + $1.sessionCount }
    }

    var allTimeTokens: Int {
        periodStats.reduce(0) { $0 + $1.totalTokens }
    }

    var allTimeMessages: Int {
        periodStats.reduce(0) { $0 + $1.messageCount }
    }

    var visibleStats: [PeriodStats] {
        Array(periodStats.prefix(selectedPeriod.displayCount))
    }

    var visibleModelBreakdown: [ModelUsage] {
        modelBreakdown(for: visibleStats)
    }

    /// Aggregate trend data for a given period from parsed session stats
    func aggregateTrendData(for period: PeriodStats, periodType: StatsPeriod) -> [TrendDataPoint] {
        let granularity = periodType.trendGranularity
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        // Daily view → hourSlices; weekly/monthly/yearly → daySlices (derived from hourSlices)
        let useHourSlices = periodType == .daily

        for (sessionId, stats) in parsedStats {
            let slices: [Date: SessionStats.DaySlice] = useHourSlices ? stats.hourSlices : stats.daySlices
            if !slices.isEmpty {
                for (sliceTime, slice) in slices {
                    let slicePeriodStart = periodType.startOfPeriod(for: sliceTime)
                    guard slicePeriodStart == period.period else { continue }

                    let bucket = granularity.bucketStart(for: sliceTime)
                    var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
                    existing.tokens += slice.totalTokens
                    existing.cost += slice.estimatedCost
                    buckets[bucket] = existing
                }
            } else {
                // Fallback for sessions without hourSlice data
                guard let session = sessions.first(where: { $0.id == sessionId }) else { continue }
                let sessionDate = stats.startTime ?? session.lastModified
                let sessionPeriodStart = periodType.startOfPeriod(for: sessionDate)
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

        // Zero-origin at the period start
        if !sorted.isEmpty {
            result.append(TrendDataPoint(time: period.period, tokens: 0, cost: 0))
        }

        // Data points at the END of each bucket (cumulative up to that point)
        var cumTokens = 0
        var cumCost = 0.0
        for (i, (time, val)) in sorted.enumerated() {
            cumTokens += val.tokens
            cumCost += val.cost
            // End of bucket = start of next granularity unit
            // For the last bucket, cap at "now" to avoid showing future time
            let bucketEnd = cal.date(byAdding: granularity.calendarComponent, value: 1, to: time)!
            let dataTime = (i == sorted.count - 1) ? min(bucketEnd, Date()) : bucketEnd
            result.append(TrendDataPoint(time: dataTime, tokens: cumTokens, cost: cumCost))
        }
        return result
    }

    var globalModelBreakdown: [ModelUsage] {
        modelBreakdown(for: periodStats)
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
