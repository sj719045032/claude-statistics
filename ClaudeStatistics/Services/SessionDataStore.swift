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

    private var fileFingerprints: [String: FileFingerprint] = [:]
    private var dirtySessionIds: Set<String> = []
    private var isPopoverVisible = false
    private var watcher: FSEventsWatcher?
    private let parseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        q.name = "com.claude-statistics.parse"
        return q
    }()

    struct FileFingerprint {
        let size: Int64
        let mtime: Date
    }

    // MARK: - Lifecycle

    func start() {
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
            let scannedSessions = SessionScanner.shared.scanSessions()

            await MainActor.run {
                guard let self else { return }
                self.sessions = scannedSessions
                self.buildFingerprints()
                self.parseProgress = "Loading quick stats..."
            }

            // Quick parse all sessions
            var quickMap: [String: TranscriptParser.QuickStats] = [:]
            for session in scannedSessions {
                quickMap[session.id] = TranscriptParser.shared.parseSessionQuick(at: session.filePath)
            }

            await MainActor.run {
                guard let self else { return }
                self.quickStats = quickMap
                self.parseProgress = "Parsing details..."
            }

            // Full parse all sessions (serial, one at a time)
            let total = scannedSessions.count
            for (i, session) in scannedSessions.enumerated() {
                let stats = TranscriptParser.shared.parseSession(at: session.filePath)

                await MainActor.run {
                    guard let self else { return }
                    self.parsedStats[session.id] = stats
                    if (i + 1) % 20 == 0 || i == total - 1 {
                        self.parseProgress = "Parsing \(i + 1)/\(total)..."
                        self.rebucket()
                    }
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.rebucket()
                self.isFullParseComplete = true
                self.parseProgress = nil
            }
        }
    }

    // MARK: - File change handling

    private func handleFileChanges(_ changedPaths: Set<String>) {
        // Map file paths to session ids and detect actual changes
        var changedIds: Set<String> = []

        for path in changedPaths {
            let fileName = (path as NSString).lastPathComponent
            guard fileName.hasSuffix(".jsonl") else { continue }
            let sessionId = (fileName as NSString).deletingPathExtension

            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: path) else {
                // File deleted — will handle in rescan
                changedIds.insert(sessionId)
                continue
            }

            let newSize = attrs[.size] as? Int64 ?? 0
            let newMtime = attrs[.modificationDate] as? Date ?? Date.distantPast

            if let existing = fileFingerprints[sessionId] {
                if existing.size == newSize && existing.mtime == newMtime {
                    continue // No actual change
                }
            }
            changedIds.insert(sessionId)
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
            // Rescan to pick up new/deleted files
            let scannedSessions = SessionScanner.shared.scanSessions()

            await MainActor.run {
                guard let self else { return }
                self.sessions = scannedSessions
                self.buildFingerprints()
                self.cleanupDeletedSessions(current: scannedSessions)
            }

            // Quick-parse changed sessions
            for session in scannedSessions where ids.contains(session.id) {
                let quick = TranscriptParser.shared.parseSessionQuick(at: session.filePath)
                await MainActor.run {
                    self?.quickStats[session.id] = quick
                }
            }

            // Full-parse changed sessions
            for session in scannedSessions where ids.contains(session.id) {
                let stats = TranscriptParser.shared.parseSession(at: session.filePath)
                await MainActor.run {
                    guard let self else { return }
                    self.parsedStats[session.id] = stats
                }
            }

            await MainActor.run {
                self?.rebucket()
            }
        }
    }

    // MARK: - Rebucket

    private func rebucket() {
        guard !parsedStats.isEmpty else { return }

        var buckets: [Date: PeriodStats] = [:]

        for (sessionId, stats) in parsedStats {
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
            fileFingerprints.removeValue(forKey: id)
        }
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
        initialLoad()
    }

    // MARK: - Helpers

    private func buildFingerprints() {
        fileFingerprints.removeAll()
        for session in sessions {
            fileFingerprints[session.id] = FileFingerprint(
                size: session.fileSize,
                mtime: session.lastModified
            )
        }
    }

    private func cleanupDeletedSessions(current: [Session]) {
        let currentIds = Set(current.map(\.id))
        let staleIds = Set(parsedStats.keys).subtracting(currentIds)
        for id in staleIds {
            parsedStats.removeValue(forKey: id)
            quickStats.removeValue(forKey: id)
            fileFingerprints.removeValue(forKey: id)
        }
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

        for (sessionId, stats) in parsedStats {
            guard let session = sessions.first(where: { $0.id == sessionId }) else { continue }
            let sessionDate = stats.startTime ?? session.lastModified
            let sessionPeriodStart = periodType.startOfPeriod(for: sessionDate)

            // Only include sessions in this period
            guard sessionPeriodStart == period.period else { continue }

            let bucket = granularity.bucketStart(for: sessionDate)
            let tokens = stats.totalTokens
            let cost = stats.estimatedCost

            var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
            existing.tokens += tokens
            existing.cost += cost
            buckets[bucket] = existing
        }

        return buckets.map { TrendDataPoint(time: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.time < $1.time }
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
