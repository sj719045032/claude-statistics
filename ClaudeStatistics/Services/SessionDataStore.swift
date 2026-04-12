import Foundation
import SwiftUI

@MainActor
final class SessionDataStore: ObservableObject {
    // MARK: - Published state (UI binds to these)

    @Published var sessions: [Session] = []
    @Published var quickStats: [String: TranscriptParser.QuickStats] = [:]
    @Published var parsedStats: [String: SessionStats] = [:]
    @Published var selectedPeriod: StatsPeriod = .daily { didSet { rebucket() } }
    @Published var weeklyResetDate: Date? { didSet { if selectedPeriod == .weekly { rebucket() } } }
    @Published var periodStats: [PeriodStats] = []
    @Published var isFullParseComplete = false
    @Published var parseProgress: String?
    @Published var parsePercent: Double?

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

            // Full parse + index dirty sessions (parse in parallel, DB write serial)
            let total = dirtyIds.count
            let parseStart = CFAbsoluteTimeGetCurrent()
            let batchSize = 8
            var processed = 0

            for batchStart in stride(from: 0, to: total, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, total)
                let batch = Array(dirtyIds[batchStart..<batchEnd])

                // Parse batch in parallel
                let results = await withTaskGroup(of: (Session, SessionStats).self) { group in
                    for session in batch {
                        group.addTask {
                            let stats = TranscriptParser.shared.parseSession(at: session.filePath)
                            return (session, stats)
                        }
                    }
                    var batchResults: [(Session, SessionStats)] = []
                    for await result in group {
                        batchResults.append(result)
                    }
                    return batchResults
                }

                // DB write + UI update (serial)
                for (session, stats) in results {
                    db.saveSessionStats(sessionId: session.id, stats: stats)
                    db.indexSession(sessionId: session.id, filePath: session.filePath)
                }
                processed += results.count

                await MainActor.run {
                    for (session, stats) in results {
                        self.parsedStats[session.id] = stats
                    }
                    self.parseProgress = "Parsing \(processed)/\(total)"
                    self.parsePercent = Double(processed) / Double(total)
                    if processed % 20 < batchSize || processed == total {
                        self.rebucket()
                    }
                }
            }

            let parseTotal = CFAbsoluteTimeGetCurrent() - parseStart
            DiagnosticLogger.shared.parsePerf(
                sessions: total, subagentSessions: 0,
                parseTime: parseTotal, dbTime: 0, indexTime: 0
            )

            // Clean up DB entries for deleted sessions
            let currentIds = Set(scannedSessions.map(\.id))
            let staleIds = Set(cache.keys).subtracting(currentIds)
            if !staleIds.isEmpty { db.removeSessions(staleIds) }

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
            let total = dirtySessions.count
            let showProgress = total > 3

            if showProgress {
                await MainActor.run { self.parseProgress = "Updating..." }
            }

            for (i, session) in dirtySessions.enumerated() {
                let quick = TranscriptParser.shared.parseSessionQuick(at: session.filePath)
                db.saveQuickStats(sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified, stats: quick)
                await MainActor.run { self.quickStats[session.id] = quick }

                let stats = TranscriptParser.shared.parseSession(at: session.filePath)
                db.saveSessionStats(sessionId: session.id, stats: stats)
                db.indexSession(sessionId: session.id, filePath: session.filePath)
                await MainActor.run {
                    self.parsedStats[session.id] = stats
                    if showProgress {
                        self.parseProgress = "Updating \(i + 1)/\(total)"
                        self.parsePercent = Double(i + 1) / Double(total)
                    }
                }
            }

            if showProgress {
                await MainActor.run {
                    self.parseProgress = nil
                    self.parsePercent = nil
                }
            }

            await MainActor.run { self.rebucket() }
        }
    }

    // MARK: - Rebucket

    private func rebucket() {
        guard !parsedStats.isEmpty else { return }

        var buckets: [Date: PeriodStats] = [:]
        var periodSessionIds: [Date: Set<String>] = [:]

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
            }
        }

        // Set accurate session counts (one session counted once per period)
        for (period, ids) in periodSessionIds {
            buckets[period]?.sessionCount = ids.count
        }

        periodStats = buckets.values.sorted { $0.period > $1.period }

        // Update cached aggregates
        allTimeCost = parsedStats.values.reduce(0) { $0 + $1.estimatedCost }
        allTimeSessions = parsedStats.count
        allTimeTokens = parsedStats.values.reduce(0) { $0 + $1.totalTokens }
        allTimeMessages = parsedStats.values.reduce(0) { $0 + $1.messageCount }
        visibleStats = Array(periodStats.prefix(selectedPeriod.displayCount))
        visibleModelBreakdown = modelBreakdown(for: visibleStats)
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

    // MARK: - Cached aggregates (updated in rebucket)

    @Published private(set) var allTimeCost: Double = 0
    @Published private(set) var allTimeSessions: Int = 0
    @Published private(set) var allTimeTokens: Int = 0
    @Published private(set) var allTimeMessages: Int = 0
    @Published private(set) var visibleStats: [PeriodStats] = []
    @Published private(set) var visibleModelBreakdown: [ModelUsage] = []

    /// Aggregate trend data for a given period from parsed session stats
    func aggregateTrendData(for period: PeriodStats, periodType: StatsPeriod) -> [TrendDataPoint] {
        let granularity = periodType.trendGranularity
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        // Use fiveMinSlices for daily view or weekly with non-midnight subscription boundary
        let useFineSlices = periodType == .daily || (periodType == .weekly && weeklyResetDate != nil)

        let resetDate = weeklyResetDate

        for (sessionId, stats) in parsedStats {
            let slices: [Date: SessionStats.DaySlice] = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            if !slices.isEmpty {
                for (sliceTime, slice) in slices {
                    let slicePeriodStart = periodType.startOfPeriod(for: sliceTime, weeklyResetDate: resetDate)
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
                let sessionPeriodStart = periodType.startOfPeriod(for: sessionDate, weeklyResetDate: resetDate)
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
        let sliceDuration: TimeInterval = useFineSlices ? 5 * 60 : 24 * 3600
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        for stats in parsedStats.values {
            let slices: [Date: SessionStats.DaySlice] = useFineSlices ? stats.fiveMinSlices : stats.daySlices
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

            // Data from the first partial bucket was accumulated but not yet plotted.
            // Show it at the next bucket boundary (already included in cumTokens/cumCost above).
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

    func windowModelBreakdown(from start: Date, to end: Date, modelFilter: ((String) -> Bool)? = nil) -> [ModelUsage] {
        guard start < end else { return [] }

        let useFineSlices = true // always use fine slices for window queries
        let sliceDuration: TimeInterval = 5 * 60
        var combined: [String: ModelUsage] = [:]

        for stats in parsedStats.values {
            let slices: [Date: SessionStats.DaySlice] = useFineSlices ? stats.fiveMinSlices : stats.daySlices
            for (sliceTime, slice) in slices {
                // Exclusive start: data at exact boundary belongs to previous period
                guard sliceTime > start, sliceTime < end else { continue }

                for (model, modelStats) in slice.modelBreakdown {
                    if let filter = modelFilter, !filter(model) { continue }
                    var existing = combined[model] ?? ModelUsage(model: model)
                    existing.inputTokens += modelStats.inputTokens
                    existing.outputTokens += modelStats.outputTokens
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
                }
            }
        }
        return combined.values.sorted { $0.totalTokens > $1.totalTokens }
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
