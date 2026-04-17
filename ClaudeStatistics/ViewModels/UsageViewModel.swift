import Foundation
import SwiftUI

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var autoRefreshInterval: TimeInterval = 300
    @Published private(set) var dashboardURL: URL?

    private var autoRefresh: AutoRefreshCoordinator?
    private var usageSource: (any ProviderUsageSource)?
    private var usagePresentation: ProviderUsagePresentation = .standard
    weak var store: SessionDataStore?

    init() {
        // Create coordinator after all stored properties are initialized
        self.autoRefresh = AutoRefreshCoordinator { [weak self] in
            guard let self else { return }
            await self.refresh()
        }

        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        autoRefreshInterval = interval > 0 ? interval : 300
    }

    func configure(source: (any ProviderUsageSource)?, usagePresentation: ProviderUsagePresentation) {
        stopAutoRefresh()
        usageSource = source
        self.usagePresentation = usagePresentation
        dashboardURL = source?.dashboardURL
        usageData = nil
        errorMessage = nil
        lastFetchedAt = nil
        isLoading = false
    }

    func loadCache() {
        if let cached = usageSource?.loadCachedSnapshot() {
            usageData = cached.data
            lastFetchedAt = cached.fetchedAt
        } else {
            usageData = nil
            lastFetchedAt = nil
        }
    }

    /// Auto-refresh: timer controls the interval, always call API
    func refresh() async {
        await refreshUsage(showRateLimitError: false)
    }

    /// Manual refresh: try API, but show meaningful feedback on 429
    func forceRefresh() async {
        await refreshUsage(showRateLimitError: true)
    }

    private func refreshUsage(showRateLimitError: Bool) async {
        isLoading = true
        errorMessage = nil

        do {
            guard let usageSource else {
                throw UsageError.invalidResponse
            }
            let snapshot = try await usageSource.refreshSnapshot()
            usageData = snapshot.data
            lastFetchedAt = snapshot.fetchedAt
            errorMessage = nil
        } catch let error as UsageError {
            switch error {
            case .rateLimited:
                if showRateLimitError {
                    errorMessage = error.localizedDescription
                } else {
                    loadCache()
                }
            case .unauthorized:
                let refreshed = await usageSource?.refreshCredentials() ?? false
                if refreshed {
                    do {
                        guard let usageSource else {
                            throw UsageError.invalidResponse
                        }
                        let snapshot = try await usageSource.refreshSnapshot()
                        usageData = snapshot.data
                        lastFetchedAt = snapshot.fetchedAt
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

        Task { [weak self] in
            guard let self else { return }
            await self.refreshIfStale()
        }
    }

    func stopAutoRefresh() {
        autoRefresh?.stop()
    }

    func clearForUnsupportedProvider() {
        configure(source: nil, usagePresentation: usagePresentation)
    }

    private func refreshIfStale() async {
        guard !isLoading else { return }
        guard let lastFetchedAt else {
            await refresh()
            return
        }

        let age = Date().timeIntervalSince(lastFetchedAt)
        guard age >= autoRefreshInterval else { return }
        await refresh()
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

    /// Predicts when a usage window will be exhausted.
    ///
    /// 5h: linear from current window, requires utilization ≥ 10%.
    /// 7d: 14-day historical average rate (if ≥1 completed window exists),
    ///     else linear fallback requiring elapsed ≥ 1 day.
    private func exhaustEstimate(
        for window: UsageWindow?,
        windowDuration: TimeInterval,
        isFiveHour: Bool = false
    ) -> (text: String, willExhaust: Bool)? {
        guard let window,
              let timeUntilReset = window.timeUntilReset else { return nil }

        let elapsed = windowDuration - timeUntilReset
        guard elapsed > 0 else { return nil }

        let remaining = 100.0 - window.utilization
        guard remaining > 0 else { return nil }

        let rate: Double
        if isFiveHour {
            guard window.utilization >= 10 else { return nil }
            rate = window.utilization / elapsed
        } else if let histRate = usageSource?.historyStore?.sevenDayAverageRate() {
            rate = histRate
        } else {
            guard elapsed >= 86400 else { return nil }
            rate = window.utilization / elapsed
        }

        guard rate > 0 else { return nil }
        let secondsToExhaust = remaining / rate
        let willExhaust = secondsToExhaust < timeUntilReset
        return (text: TimeFormatter.countdown(from: secondsToExhaust), willExhaust: willExhaust)
    }

    var fiveHourExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(for: usageData?.fiveHour, windowDuration: 5 * 3600, isFiveHour: true)
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

    var primaryQuotaBucket: ProviderUsageBucket? {
        usageData?.providerBuckets?.first
    }

    private var menuBarQuotaBucket: ProviderUsageBucket? {
        guard let buckets = usageData?.providerBuckets else { return nil }
        return buckets.first { $0.remainingPercentage > 0 } ?? buckets.first
    }

    var statusColor: Color {
        switch usagePresentation.menuBarMetric {
        case .preferredWindow:
            let preferredUtilization: Double
            switch usagePresentation.preferredWindow {
            case .short:
                preferredUtilization = usageData?.fiveHour?.utilization ?? max(fiveHourPercent, sevenDayPercent)
            case .long:
                preferredUtilization = usageData?.sevenDay?.utilization ?? max(fiveHourPercent, sevenDayPercent)
            }
            if preferredUtilization >= 80 { return .red }
            if preferredUtilization >= 50 { return .orange }
        case .primaryQuotaBucket:
            let usedPercentage = 100 - (menuBarQuotaBucket?.remainingPercentage ?? 0)
            if usedPercentage >= 80 { return .red }
            if usedPercentage >= 50 { return .orange }
        }
        return .green
    }

    var menuBarText: String {
        switch usagePresentation.menuBarMetric {
        case .preferredWindow:
            switch usagePresentation.preferredWindow {
            case .short:
                if usageData?.fiveHour != nil {
                    return "\(Int(fiveHourPercent))%"
                }
                if usageData?.sevenDay != nil {
                    return "\(Int(sevenDayPercent))%"
                }
            case .long:
                if usageData?.sevenDay != nil {
                    return "\(Int(sevenDayPercent))%"
                }
                if usageData?.fiveHour != nil {
                    return "\(Int(fiveHourPercent))%"
                }
            }
        case .primaryQuotaBucket:
            if let bucket = menuBarQuotaBucket {
                return quotaMenuBarText(for: bucket)
            }
        }
        return ""
    }

    private func quotaMenuBarText(for bucket: ProviderUsageBucket) -> String {
        let title = bucket.title
        if let remaining = bucket.remainingAmount, let limit = bucket.limitAmount {
            return "\(title) \(formatQuotaAmount(remaining))/\(formatQuotaAmount(limit))"
        }
        if let remaining = bucket.remainingAmount {
            return "\(title) \(formatQuotaAmount(remaining))"
        }
        return "\(title) \(Int(bucket.remainingPercentage.rounded()))%"
    }

    private func formatQuotaAmount(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return Int(rounded).formatted()
        }
        return String(format: "%.1f", value)
    }
}
