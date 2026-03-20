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
    }

    func loadCache() {
        if let cached = UsageAPIService.shared.loadFromCache() {
            usageData = cached.data
            lastFetchedAt = cached.fetchedAt
        }
    }

    /// Auto-refresh: only call API if cache is stale
    func refresh() async {
        loadCache()
        let cacheAge = lastFetchedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if cacheAge > 300 {
            await callAPI()
        }
    }

    /// Manual refresh: try API, but show meaningful feedback on 429
    func forceRefresh() async {
        isLoading = true
        errorMessage = nil

        do {
            let data = try await UsageAPIService.shared.fetchUsage()
            usageData = data
            lastFetchedAt = Date()
        } catch let error as UsageError {
            if case .rateLimited = error {
                errorMessage = "API unavailable"
            } else {
                errorMessage = error.localizedDescription
            }
            if usageData == nil { loadCache() }
        } catch {
            errorMessage = error.localizedDescription
            if usageData == nil { loadCache() }
        }

        isLoading = false
    }

    private func callAPI() async {
        // Respect rate limit
        if let retryAfter = UsageAPIService.shared.retryAfter, Date() < retryAfter {
            // Have data → stay silent; no data → show error with web link
            if usageData == nil {
                let wait = max(1, Int(ceil(retryAfter.timeIntervalSinceNow)))
                errorMessage = "Rate limited, retry in \(wait)s"
            }
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
            if case .rateLimited = error, usageData != nil {
                // Have cached data, don't show error
            } else {
                errorMessage = error.localizedDescription
            }
            if usageData == nil { loadCache() }
        } catch {
            if usageData == nil {
                errorMessage = error.localizedDescription
                loadCache()
            }
        }

        isLoading = false
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
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
