import Foundation
import SwiftUI
import Combine

@MainActor
final class StatisticsViewModel: ObservableObject {
    let store: SessionDataStore
    private var cancellable: AnyCancellable?

    init(store: SessionDataStore) {
        self.store = store
        // Forward store's objectWillChange so SwiftUI picks up changes
        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Selected period (read/write pass-through)

    var selectedPeriod: StatsPeriod {
        get { store.selectedPeriod }
        set { store.selectedPeriod = newValue }
    }

    // MARK: - Loading state

    var isLoading: Bool { !store.isFullParseComplete }
    var progress: String? { store.parseProgress }

    // MARK: - Period stats

    var periodStats: [PeriodStats] { store.periodStats }

    var visibleStats: [PeriodStats] {
        Array(store.periodStats.prefix(store.selectedPeriod.displayCount))
    }

    // MARK: - All-time aggregates

    var allTimeCost: Double {
        store.periodStats.reduce(0) { $0 + $1.totalCost }
    }

    var allTimeSessions: Int {
        store.periodStats.reduce(0) { $0 + $1.sessionCount }
    }

    var allTimeTokens: Int {
        store.periodStats.reduce(0) { $0 + $1.totalTokens }
    }

    var allTimeMessages: Int {
        store.periodStats.reduce(0) { $0 + $1.messageCount }
    }

    // MARK: - Model breakdowns

    var visibleModelBreakdown: [ModelUsage] {
        modelBreakdown(for: visibleStats)
    }

    var globalModelBreakdown: [ModelUsage] {
        modelBreakdown(for: store.periodStats)
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
