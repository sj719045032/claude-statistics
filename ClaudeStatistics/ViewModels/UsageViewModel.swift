import Foundation
import SwiftUI

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var autoRefreshInterval: TimeInterval = 300

    private var autoRefresh: AutoRefreshCoordinator?
    weak var store: SessionDataStore?

    init() {
        loadCache()

        // Create coordinator after all stored properties are initialized
        self.autoRefresh = AutoRefreshCoordinator { [weak self] in
            guard let self else { return }
            await self.refresh()
        }

        let enabled = UserDefaults.standard.bool(forKey: "autoRefreshEnabled")
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        if enabled {
            autoRefreshInterval = interval > 0 ? interval : 300
            Task { @MainActor in
                // Skip API call on launch if cache is fresh enough
                if let cached = UsageAPIService.shared.loadFromCache(),
                   Date().timeIntervalSince(cached.fetchedAt) < autoRefreshInterval {
                    usageData = cached.data
                    lastFetchedAt = cached.fetchedAt
                } else {
                    await self.refresh()
                }
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

    /// Auto-refresh: timer controls the interval, always call API
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
            switch error {
            case .rateLimited:
                loadCache()
            case .unauthorized:
                // Ask Claude Code CLI to refresh the token, then retry
                let refreshed = await UsageAPIService.shared.refreshToken()
                if refreshed {
                    do {
                        let data = try await UsageAPIService.shared.fetchUsage()
                        usageData = data
                        lastFetchedAt = Date()
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                        if usageData == nil { loadCache() }
                    }
                } else {
                    errorMessage = UsageError.unauthorized.localizedDescription
                    if usageData == nil { loadCache() }
                }
            default:
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
        autoRefresh?.start(interval: autoRefreshInterval)
    }

    func stopAutoRefresh() {
        autoRefresh?.stop()
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

    /// Predicts when a usage window will be exhausted, using local session data to weight recent activity.
    /// Falls back to simple linear extrapolation when local data is insufficient.
    private func exhaustEstimate(for window: UsageWindow?, windowDuration: TimeInterval) -> (text: String, willExhaust: Bool)? {
        guard let window,
              window.utilization >= 10,
              let timeUntilReset = window.timeUntilReset else { return nil }

        let elapsed = windowDuration - timeUntilReset
        guard elapsed > 0 else { return nil }

        let avgRate = window.utilization / elapsed
        guard avgRate > 0 else { return nil }

        let remaining = 100.0 - window.utilization
        guard remaining > 0 else { return nil }

        // Apply recent-activity multiplier from local session data if available
        let effectiveRate = avgRate * (recentRateMultiplier(elapsed: elapsed) ?? 1.0)

        let secondsToExhaust = remaining / effectiveRate
        let willExhaust = secondsToExhaust < timeUntilReset
        return (text: TimeFormatter.countdown(from: secondsToExhaust), willExhaust: willExhaust)
    }

    /// Computes how much faster/slower recent activity is vs the full window average,
    /// using local fiveMinSlices cost data as a proxy. Returns nil if data is insufficient.
    private func recentRateMultiplier(elapsed: TimeInterval) -> Double? {
        guard let store else { return nil }

        let recentWindow: TimeInterval = min(30 * 60, elapsed * 0.3)
        let now = Date()
        let recentStart = now.addingTimeInterval(-recentWindow)
        let fullStart = now.addingTimeInterval(-elapsed)

        var recentCost: Double = 0
        var fullCost: Double = 0
        var recentSliceCount = 0

        for stats in store.parsedStats.values {
            for (time, slice) in stats.fiveMinSlices {
                guard time > fullStart, time <= now else { continue }
                fullCost += slice.estimatedCost
                if time > recentStart {
                    recentCost += slice.estimatedCost
                    recentSliceCount += 1
                }
            }
        }

        guard recentSliceCount >= 3, fullCost > 0 else { return nil }

        let recentRate = recentCost / recentWindow
        let fullRate = fullCost / elapsed
        guard fullRate > 0 else { return nil }

        return min(max(recentRate / fullRate, 0.1), 10.0)
    }

    var fiveHourExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(for: usageData?.fiveHour, windowDuration: 5 * 3600)
    }

    var sevenDayExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(for: usageData?.sevenDay, windowDuration: 7 * 86400)
    }

    var sevenDayOpusExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(for: usageData?.sevenDayOpus, windowDuration: 7 * 86400)
    }

    var sevenDaySonnetExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(for: usageData?.sevenDaySonnet, windowDuration: 7 * 86400)
    }

    var statusColor: Color {
        let maxUtil = max(fiveHourPercent, sevenDayPercent)
        if maxUtil >= 80 { return .red }
        if maxUtil >= 50 { return .orange }
        return .green
    }

    var menuBarText: String {
        "\(Int(fiveHourPercent))%"
    }
}
