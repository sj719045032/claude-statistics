import Foundation
import SwiftUI
import Combine

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var autoRefreshInterval: TimeInterval = 300

    private var refreshTimer: Timer?

    init() {
        loadCache()
        // Restore auto-refresh from persisted setting
        let enabled = UserDefaults.standard.bool(forKey: "autoRefreshEnabled")
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        if enabled {
            autoRefreshInterval = interval > 0 ? interval : 300
            Task { @MainActor in
                await self.refresh()
            }
            startAutoRefresh()
        }
    }

    func loadCache() {
        if let cached = UsageAPIService.shared.loadFromCache() {
            usageData = cached.data
            lastFetchedAt = cached.fetchedAt
        }
    }

    /// Auto-refresh: always attempt API call (timer already controls the interval)
    func refresh() async {
        await callAPI()
    }

    /// Manual refresh: try API, but show meaningful feedback on 429
    func forceRefresh() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await UsageAPIService.shared.fetchUsage()
            usageData = data
            lastFetchedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
            if usageData == nil { loadCache() }
        }

        isLoading = false
    }

    private func callAPI() async {
        // Respect rate limit — but still reload cache so UI timestamp updates
        if let retryAfter = UsageAPIService.shared.retryAfter, Date() < retryAfter {
            loadCache()
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let data = try await UsageAPIService.shared.fetchUsage()
            usageData = data
            lastFetchedAt = Date()
            errorMessage = nil
        } catch let error as UsageError {
            if case .rateLimited = error {
                loadCache()
            } else {
                errorMessage = error.localizedDescription
                if usageData == nil { loadCache() }
            }
        } catch {
            errorMessage = error.localizedDescription
            if usageData == nil { loadCache() }
        }

        isLoading = false
    }

    func startAutoRefresh() {
        // Skip if timer already running with the same interval
        if let existing = refreshTimer, existing.isValid,
           existing.timeInterval == autoRefreshInterval {
            return
        }
        stopAutoRefresh()
        let interval = autoRefreshInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Computed display properties

    var fiveHourPercent: Double {
        usageData?.fiveHour?.utilization ?? 0
    }

    var sevenDayPercent: Double {
        usageData?.sevenDay?.utilization ?? 0
    }

    var fiveHourResetCountdown: String? {
        guard let interval = usageData?.fiveHour?.timeUntilReset else { return nil }
        return TimeFormatter.countdown(from: interval)
    }

    var sevenDayResetCountdown: String? {
        guard let interval = usageData?.sevenDay?.timeUntilReset else { return nil }
        return TimeFormatter.countdown(from: interval)
    }

    var statusColor: Color {
        let maxUtil = max(fiveHourPercent, sevenDayPercent)
        if maxUtil >= 80 { return .red }
        if maxUtil >= 50 { return .orange }
        return .green
    }

    var menuBarText: String {
        let pct = fiveHourPercent
        return "\(Int(pct))%"
    }
}
