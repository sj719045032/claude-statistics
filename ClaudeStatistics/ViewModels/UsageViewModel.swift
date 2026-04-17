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

    private static let activeHourCostThreshold: Double = 0.10
    private static let dutyCycleLookbackDays: Int = 14
    private static let defaultDutyCycle: Double = 0.42
    private static let minElapsedForActiveRate: TimeInterval = 3 * 3600

    /// Predicts when a usage window will be exhausted. For long windows, uses active-hour
    /// rate weighted against overall baseline, then scales remaining time by the user's
    /// estimated daily duty cycle (so sleep/off-hours don't count as burn time).
    private func exhaustEstimate(
        for window: UsageWindow?,
        windowDuration: TimeInterval,
        recentWindowCap: TimeInterval,
        baselineWeight: Double,
        useDutyCycle: Bool
    ) -> (text: String, willExhaust: Bool)? {
        guard let window,
              window.utilization >= 10,
              let timeUntilReset = window.timeUntilReset else { return nil }

        let elapsed = windowDuration - timeUntilReset
        guard elapsed > 0 else { return nil }

        let remaining = 100.0 - window.utilization
        guard remaining > 0 else { return nil }

        let rawMultiplier = recentRateMultiplier(elapsed: elapsed, recentWindowCap: recentWindowCap) ?? 1.0
        let weightedMultiplier = baselineWeight + (1.0 - baselineWeight) * rawMultiplier

        let secondsToExhaust: Double
        if useDutyCycle, elapsed >= Self.minElapsedForActiveRate {
            let now = Date()
            let from = now.addingTimeInterval(-elapsed)
            let elapsedActiveHours = Double(activeHoursInRange(from: from, to: now))
            if elapsedActiveHours >= 1 {
                let activeRate = window.utilization / elapsedActiveHours
                let effectiveActiveRate = activeRate * weightedMultiplier
                guard effectiveActiveRate > 0 else { return nil }
                let remainingActiveHours = remaining / effectiveActiveRate
                let dutyCycle = estimateDutyCycle()
                secondsToExhaust = remainingActiveHours * 3600 / dutyCycle
            } else {
                let avgRate = window.utilization / elapsed
                guard avgRate > 0 else { return nil }
                secondsToExhaust = remaining / (avgRate * weightedMultiplier)
            }
        } else {
            let avgRate = window.utilization / elapsed
            guard avgRate > 0 else { return nil }
            secondsToExhaust = remaining / (avgRate * weightedMultiplier)
        }

        let willExhaust = secondsToExhaust < timeUntilReset
        return (text: TimeFormatter.countdown(from: secondsToExhaust), willExhaust: willExhaust)
    }

    /// Computes how much faster/slower recent activity is vs the full window average,
    /// using local fiveMinSlices cost data as a proxy. Returns nil if data is insufficient.
    private func recentRateMultiplier(elapsed: TimeInterval, recentWindowCap: TimeInterval) -> Double? {
        guard let store else { return nil }

        let recentWindow: TimeInterval = min(recentWindowCap, elapsed * 0.3)
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

    /// Counts whole hours within [from, to) whose aggregated cost exceeds the threshold.
    private func activeHoursInRange(from: Date, to: Date, threshold: Double = UsageViewModel.activeHourCostThreshold) -> Int {
        guard let store, from < to else { return 0 }
        let cal = Calendar.current
        var hourCosts: [Date: Double] = [:]
        for stats in store.parsedStats.values {
            for (time, slice) in stats.fiveMinSlices {
                guard time >= from, time < to else { continue }
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: time)
                guard let hourStart = cal.date(from: comps) else { continue }
                hourCosts[hourStart, default: 0] += slice.estimatedCost
            }
        }
        return hourCosts.values.reduce(into: 0) { $0 += ($1 > threshold ? 1 : 0) }
    }

    /// Estimates the fraction of a day the user is actively consuming quota, using the
    /// recent 14-day history. Falls back to `defaultDutyCycle` when data span is insufficient.
    private func estimateDutyCycle() -> Double {
        guard let store else { return Self.defaultDutyCycle }

        let now = Date()
        let lookbackLimit = now.addingTimeInterval(-TimeInterval(Self.dutyCycleLookbackDays) * 86400)

        var earliest = now
        for stats in store.parsedStats.values {
            for time in stats.fiveMinSlices.keys where time < earliest {
                earliest = time
            }
        }

        let from = max(earliest, lookbackLimit)
        let spanSeconds = now.timeIntervalSince(from)
        guard spanSeconds >= 2 * 86400 else { return Self.defaultDutyCycle }

        let totalHours = spanSeconds / 3600
        guard totalHours > 0 else { return Self.defaultDutyCycle }
        let activeHours = Double(activeHoursInRange(from: from, to: now))
        let ratio = activeHours / totalHours
        return min(max(ratio, 0.1), 0.9)
    }

    var fiveHourExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(
            for: usageData?.fiveHour,
            windowDuration: 5 * 3600,
            recentWindowCap: 30 * 60,
            baselineWeight: 0,
            useDutyCycle: false
        )
    }

    var sevenDayExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(
            for: usageData?.sevenDay,
            windowDuration: 7 * 86400,
            recentWindowCap: 24 * 3600,
            baselineWeight: 0.6,
            useDutyCycle: true
        )
    }

    var sevenDayOpusExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(
            for: usageData?.sevenDayOpus,
            windowDuration: 7 * 86400,
            recentWindowCap: 24 * 3600,
            baselineWeight: 0.6,
            useDutyCycle: true
        )
    }

    var sevenDaySonnetExhaustEstimate: (text: String, willExhaust: Bool)? {
        exhaustEstimate(
            for: usageData?.sevenDaySonnet,
            windowDuration: 7 * 86400,
            recentWindowCap: 24 * 3600,
            baselineWeight: 0.6,
            useDutyCycle: true
        )
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
