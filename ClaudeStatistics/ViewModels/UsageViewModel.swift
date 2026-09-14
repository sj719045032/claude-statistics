import Foundation
import ClaudeStatisticsKit
import SwiftUI

private final class UsageCacheWatcher {
    private let filePath: String
    private let directory: String
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    init?(filePath: String, onChange: @escaping () -> Void) {
        let dir = (filePath as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return nil }

        self.filePath = filePath
        self.directory = dir
        self.onChange = onChange

        if !startFileWatch() {
            guard startDirectoryWatch() else { return nil }
        }
    }

    // Watches the file itself so in-place truncate+write (Python/Swift both do this)
    // produces .write events. Directory-level watching misses these.
    @discardableResult
    private func startFileWatch() -> Bool {
        stopFileWatch()
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            guard let self, let currentSource = self.fileSource else { return }
            let flags = currentSource.data
            self.onChange()
            // Atomic-replace scenarios invalidate the fd — reopen against the path.
            if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                _ = self.startFileWatch()
            }
        }
        source.setCancelHandler { [fd] in close(fd) }

        fileSource = source
        stopDirectoryWatch()
        source.resume()
        return true
    }

    @discardableResult
    private func startDirectoryWatch() -> Bool {
        stopDirectoryWatch()
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.filePath), self.startFileWatch() {
                self.onChange()
            }
        }
        source.setCancelHandler { [fd] in close(fd) }

        directorySource = source
        source.resume()
        return true
    }

    private func stopFileWatch() {
        fileSource?.cancel()
        fileSource = nil
    }

    private func stopDirectoryWatch() {
        directorySource?.cancel()
        directorySource = nil
    }

    func stop() {
        stopFileWatch()
        stopDirectoryWatch()
    }

    deinit {
        stop()
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usageData: UsageData?
    /// Mirrors `ProfileViewModel.subscriptionInfo` for the same
    /// provider — populated only when a `SubscriptionAdapter`
    /// (e.g. GLM) is in use. When non-nil, the menu-bar percentage
    /// and color tracks the highest-utilization quota window
    /// instead of the (unavailable) Anthropic 5h/7d data.
    @Published var subscriptionInfo: SubscriptionInfo?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var autoRefreshInterval: TimeInterval = 300
    var dashboardURL: URL? {
        subscriptionInfo?.dashboardURL ?? usageSource?.dashboardURL
    }

    private var autoRefresh: AutoRefreshCoordinator?
    private var usageSource: (any ProviderUsageSource)?
    private var usagePresentation: ProviderUsagePresentation = .standard
    private var cacheWatcher: UsageCacheWatcher?
    private var refreshTask: Task<ProviderUsageSnapshot, Error>?
    private var refreshRequestID: UUID?
    private var sourceGeneration: UInt64 = 0
    private var wantsRateLimitError = false
    private var consecutiveFailures = 0
    private var nextAutomaticRefreshAt: Date?
    private var rateLimitedUntil: Date?
    private let now: () -> Date
    weak var store: SessionDataStore?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        // Create coordinator after all stored properties are initialized
        self.autoRefresh = AutoRefreshCoordinator { [weak self] in
            guard let self else { return }
            await self.refresh()
        }

        let interval = UserDefaults.standard.double(forKey: AppPreferences.refreshInterval)
        autoRefreshInterval = interval > 0 ? interval : 300
    }

    func configure(source: (any ProviderUsageSource)?, usagePresentation: ProviderUsagePresentation) {
        sourceGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestID = nil
        consecutiveFailures = 0
        nextAutomaticRefreshAt = nil
        rateLimitedUntil = nil
        wantsRateLimitError = false
        stopAutoRefresh()
        stopWatchingCache()
        usageSource = source
        self.usagePresentation = usagePresentation
        usageData = nil
        errorMessage = nil
        lastFetchedAt = nil
        isLoading = false
        startWatchingCacheIfNeeded()
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

    /// Automatic refreshes share in-flight work and respect failure backoff.
    func refresh() async {
        await refreshUsage(showRateLimitError: false)
    }

    /// Manual refresh: try API, but show meaningful feedback on 429
    func forceRefresh() async {
        await refreshUsage(showRateLimitError: true)
    }

    private func refreshUsage(showRateLimitError: Bool) async {
        if let task = refreshTask, let requestID = refreshRequestID {
            let generation = sourceGeneration
            wantsRateLimitError = wantsRateLimitError || showRateLimitError
            completeRefresh(await task.result, generation: generation, requestID: requestID)
            return
        }
        if let until = rateLimitedUntil, until > now() {
            if showRateLimitError {
                errorMessage = rateLimitMessage(for: .rateLimited(retryInSeconds: Int(ceil(until.timeIntervalSince(now())))))
            }
            return
        }
        if !showRateLimitError, let until = nextAutomaticRefreshAt, until > now() { return }
        let generation = sourceGeneration
        let requestID = UUID()
        let source = usageSource
        isLoading = true
        errorMessage = nil
        wantsRateLimitError = showRateLimitError
        let task = Task {
            guard let source else { throw UsageError.invalidResponse }
            do {
                return try await source.refreshSnapshot()
            } catch UsageError.unauthorized {
                try Task.checkCancellation()
                guard await source.refreshCredentials() else { throw UsageError.unauthorized }
                try Task.checkCancellation()
                return try await source.refreshSnapshot()
            }
        }
        refreshTask = task
        refreshRequestID = requestID
        completeRefresh(await task.result, generation: generation, requestID: requestID)
    }

    private func completeRefresh(_ result: Result<ProviderUsageSnapshot, Error>, generation: UInt64, requestID: UUID) {
        // Account/provider replacement may have started another request while
        // a non-cooperative old plugin request was still completing.
        guard generation == sourceGeneration, refreshRequestID == requestID else { return }
        refreshTask = nil
        refreshRequestID = nil
        isLoading = false
        switch result {
        case .success(let snapshot):
            usageData = snapshot.data
            lastFetchedAt = snapshot.fetchedAt
            errorMessage = nil
            consecutiveFailures = 0
            nextAutomaticRefreshAt = nil
            rateLimitedUntil = nil
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            consecutiveFailures = min(consecutiveFailures + 1, 6)
            let delay = min(900, 30 * pow(2, Double(consecutiveFailures - 1)))
            nextAutomaticRefreshAt = now().addingTimeInterval(delay)
            if case UsageError.rateLimited(let seconds) = error {
                let until = now().addingTimeInterval(TimeInterval(max(1, seconds)))
                rateLimitedUntil = until
                nextAutomaticRefreshAt = max(nextAutomaticRefreshAt!, until)
                if wantsRateLimitError { errorMessage = rateLimitMessage(for: .rateLimited(retryInSeconds: seconds)) }
            } else {
                errorMessage = error.localizedDescription
            }
            if usageData == nil { loadCache() }
        }
    }

    func startAutoRefresh() {
        autoRefresh?.start(interval: autoRefreshInterval)
        let generation = sourceGeneration
        Task { [weak self] in
            guard let self, self.sourceGeneration == generation else { return }
            await self.refreshIfStale()
        }
    }

    func stopAutoRefresh() {
        autoRefresh?.stop()
    }

    private func rateLimitMessage(for error: UsageError) -> String {
        guard usageSource is UsageAPIService else {
            return error.localizedDescription
        }

        return error.localizedDescription
    }

    func clearForUnsupportedProvider() {
        configure(source: nil, usagePresentation: usagePresentation)
    }

    private func startWatchingCacheIfNeeded() {
        guard let cacheFilePath = usageSource?.usageCacheFilePath else { return }
        cacheWatcher = UsageCacheWatcher(filePath: cacheFilePath) { [weak self] in
            guard let self else { return }
            guard self.usageSource?.usageCacheFilePath == cacheFilePath else { return }
            self.loadCache()
        }
    }

    private func stopWatchingCache() {
        cacheWatcher?.stop()
        cacheWatcher = nil
    }

    private func refreshIfStale() async {
        guard !isLoading else { return }
        guard let lastFetchedAt else {
            await refresh()
            return
        }

        let age = now().timeIntervalSince(lastFetchedAt)
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

        if isFiveHour {
            return LinearExhaustEstimator.estimate(
                utilization: window.utilization,
                timeUntilReset: timeUntilReset,
                windowDuration: windowDuration,
                minUtilization: 10
            )
        }

        // 7d: prefer 14-day historical rate when at least one
        // completed window is on disk.
        if let histRate = usageSource?.historyStore?.sevenDayAverageRate() {
            let remaining = 100.0 - window.utilization
            guard remaining > 0, histRate > 0 else { return nil }
            let secondsToExhaust = remaining / histRate
            return (
                text: TimeFormatter.countdown(from: secondsToExhaust),
                willExhaust: secondsToExhaust < timeUntilReset
            )
        }

        // Linear fallback: only meaningful after at least a day of usage.
        return LinearExhaustEstimator.estimate(
            utilization: window.utilization,
            timeUntilReset: timeUntilReset,
            windowDuration: windowDuration,
            minElapsed: 86400
        )
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

    /// Highest-utilization quota across all subscription windows.
    /// Used by the menu bar when `subscriptionInfo` is non-nil so a
    /// GLM user sees their most-strained window (5h tokens vs.
    /// monthly calls) at a glance, matching how the existing
    /// `preferredWindow` metric picks between 5h / 7d for Anthropic.
    private var primarySubscriptionQuota: SubscriptionQuotaWindow? {
        subscriptionInfo?.quotas.max(by: { $0.percentage < $1.percentage })
    }

    var statusColor: Color {
        if let quota = primarySubscriptionQuota {
            if quota.percentage >= 80 { return .red }
            if quota.percentage >= 50 { return .orange }
            return .green
        }
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
        if let quota = primarySubscriptionQuota {
            return "\(Int(quota.percentage))%"
        }
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
