import Foundation
import SwiftUI

@MainActor
final class StatisticsViewModel: ObservableObject {
    @Published var selectedPeriod: StatsPeriod = .daily {
        didSet { rebucket() }
    }
    @Published var periodStats: [PeriodStats] = []
    @Published var isLoading = false
    @Published var progress: String?
    @Published var lastLoadedAt: Date?

    // Cached parsed results
    private(set) var cachedResults: [(session: Session, stats: SessionStats)] = []

    func loadStatistics() {
        if isLoading { return }
        isLoading = true
        progress = "Scanning sessions..."

        Task.detached { [weak self] in
            let sessions = SessionScanner.shared.scanSessions()
            let total = sessions.count
            var results: [(session: Session, stats: SessionStats)] = []

            for (i, session) in sessions.enumerated() {
                if i % 10 == 0 {
                    await MainActor.run {
                        self?.progress = "Parsing \(i + 1)/\(total)..."
                    }
                }
                let stats = TranscriptParser.shared.parseSession(at: session.filePath)
                results.append((session: session, stats: stats))
            }

            await MainActor.run {
                self?.cachedResults = results
                self?.rebucket()
                self?.isLoading = false
                self?.progress = nil
                self?.lastLoadedAt = Date()
            }
        }
    }

    private func rebucket() {
        guard !cachedResults.isEmpty else { return }

        var buckets: [Date: PeriodStats] = [:]

        for item in cachedResults {
            let date = item.stats.startTime ?? item.session.lastModified
            let periodStart = selectedPeriod.startOfPeriod(for: date)

            if buckets[periodStart] == nil {
                buckets[periodStart] = PeriodStats(
                    period: periodStart,
                    periodLabel: selectedPeriod.label(for: periodStart)
                )
            }
            buckets[periodStart]?.accumulate(stats: item.stats)
        }

        periodStats = buckets.values.sorted { $0.period > $1.period }
    }

    // MARK: - Computed

    var visibleStats: [PeriodStats] {
        Array(periodStats.prefix(selectedPeriod.displayCount))
    }

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

    /// Model breakdown for visible periods only
    var visibleModelBreakdown: [ModelUsage] {
        modelBreakdown(for: visibleStats)
    }

    /// Model breakdown across all periods
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
