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
                await self.refresh()
            }
            startAutoRefresh()
        }
    }

    func loadCache() {
        if let cached = UsageAPIService.shared.loadFromCache() {
            usageData = cached.data
            lastFetchedAt = cached.fetchedAt
            Task { @MainActor in
                await self.updateResetReminderState()
            }
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
            await updateResetReminderState()
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
            await updateResetReminderState()
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
                        await updateResetReminderState()
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

    func applyAutoRefreshSettings(enabled: Bool, interval: TimeInterval) {
        autoRefreshInterval = interval > 0 ? interval : 300

        if enabled {
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
    }

    // MARK: - Computed display properties

    var fiveHourPercent: Double {
        usageData?.fiveHour?.utilization ?? 0
    }

    var menuBarFiveHourPercent: Double? {
        usageData?.fiveHour?.utilization
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

    /// Predicts when the 5-hour window will be exhausted at the current consumption rate.
    /// Returns (estimate string, will exhaust before reset), or nil if utilization < 10%.
    var fiveHourExhaustEstimate: (text: String, willExhaust: Bool)? {
        guard let window = usageData?.fiveHour,
              window.utilization >= 10,
              let timeUntilReset = window.timeUntilReset else { return nil }

        let windowDuration: TimeInterval = 5 * 3600
        let elapsed = windowDuration - timeUntilReset
        guard elapsed > 0 else { return nil }

        let rate = window.utilization / elapsed
        guard rate > 0 else { return nil }

        let remaining = 100.0 - window.utilization
        guard remaining > 0 else { return nil }

        let secondsToExhaust = remaining / rate
        let willExhaust = secondsToExhaust < timeUntilReset
        return (text: TimeFormatter.countdown(from: secondsToExhaust), willExhaust: willExhaust)
    }

    var statusColor: Color {
        let maxUtil = max(fiveHourPercent, sevenDayPercent)
        if maxUtil >= 80 { return .red }
        if maxUtil >= 50 { return .orange }
        return .green
    }

    var hasDisplayableUsage: Bool {
        usageData != nil || isLoading
    }

    private func updateResetReminderState() async {
        await UsageResetNotificationService.shared.updateReminder(
            provider: .claude,
            utilization: usageData?.fiveHour?.utilization,
            resetAt: usageData?.fiveHour?.resetsAtDate,
            fetchedAt: lastFetchedAt
        )
    }
}
