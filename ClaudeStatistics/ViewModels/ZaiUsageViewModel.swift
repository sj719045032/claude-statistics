import Foundation
import SwiftUI

@MainActor
final class ZaiUsageViewModel: ObservableObject {
    @Published var quotaLimits: [ZaiQuotaLimitDisplay]?
    @Published var modelUsage: ZaiModelUsageDisplay?
    @Published var selectedRange: ZaiTimeRange = .day
    @Published var isLoading = false
    @Published var isChartLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var isConfigured: Bool

    private var autoRefresh: AutoRefreshCoordinator?
    private var didSetup = false
    @Published var autoRefreshInterval: TimeInterval = 300

    init() {
        // Defer keychain check — running /usr/bin/security synchronously
        // during SwiftUI init causes AttributeGraph crashes
        isConfigured = false

        self.autoRefresh = AutoRefreshCoordinator { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    /// Call after init to check keychain and start auto-refresh
    func setup() {
        guard !didSetup else { return }
        didSetup = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isConfigured = await ZaiCredentialService.shared.hasAPIKeyAsync()
            self.loadCache()

            let enabled = UserDefaults.standard.bool(forKey: "autoRefreshEnabled")
            let zaiEnabled = UserDefaults.standard.bool(forKey: "zaiUsageEnabled")
            let interval = UserDefaults.standard.double(forKey: "refreshInterval")
            self.applyAutoRefreshSettings(enabled: enabled && zaiEnabled, interval: interval)
            if enabled && zaiEnabled && self.isConfigured {
                await self.refresh()
            }
        }
    }

    func loadCache() {
        if let cached = ZaiAPIService.shared.loadFromCache() {
            quotaLimits = cached.quota
            modelUsage = cached.modelUsage
            lastFetchedAt = cached.fetchedAt
            Task { @MainActor in
                await self.updateResetReminderState()
            }
        }
    }

    func refresh() async {
        guard isConfigured else { return }
        await fetchAll()
    }

    func forceRefresh() async {
        guard isConfigured else { return }
        isLoading = true
        errorMessage = nil

        do {
            let quota = try await ZaiAPIService.shared.fetchQuotaLimits()
            let usage = try await ZaiAPIService.shared.fetchModelUsage(range: selectedRange)
            quotaLimits = quota
            modelUsage = usage
            lastFetchedAt = Date()
            errorMessage = nil
            ZaiAPIService.shared.saveToCache(quota: quota, modelUsage: usage)
            await updateResetReminderState()
        } catch {
            errorMessage = error.localizedDescription
            if quotaLimits == nil { loadCache() }
        }

        isLoading = false
    }

    func fetchModelUsageForRange() async {
        guard isConfigured else { return }
        isChartLoading = true
        errorMessage = nil

        do {
            let usage = try await ZaiAPIService.shared.fetchModelUsage(range: selectedRange)
            modelUsage = usage
            lastFetchedAt = Date()
            // Update cache with new model usage
            ZaiAPIService.shared.saveToCache(quota: quotaLimits ?? [], modelUsage: usage)
        } catch {
            errorMessage = error.localizedDescription
        }

        isChartLoading = false
    }

    func onAPIKeyChanged(hasAPIKey: Bool) {
        isConfigured = hasAPIKey

        if hasAPIKey {
            Task { @MainActor in
                await self.forceRefresh()
            }
            applyAutoRefreshSettings(
                enabled: UserDefaults.standard.bool(forKey: "autoRefreshEnabled")
                    && UserDefaults.standard.bool(forKey: "zaiUsageEnabled"),
                interval: UserDefaults.standard.double(forKey: "refreshInterval")
            )
        } else {
            quotaLimits = nil
            modelUsage = nil
            errorMessage = nil
            stopAutoRefresh()
            Task { @MainActor in
                await UsageResetNotificationService.shared.updateReminder(
                    provider: .zai,
                    utilization: nil,
                    resetAt: nil,
                    fetchedAt: nil
                )
            }
        }
    }

    func selectRange(_ range: ZaiTimeRange) async {
        guard selectedRange != range else { return }
        selectedRange = range
        await fetchModelUsageForRange()
    }

    func applyAutoRefreshSettings(enabled: Bool, interval: TimeInterval) {
        autoRefreshInterval = interval > 0 ? interval : 300

        guard isConfigured else {
            stopAutoRefresh()
            return
        }

        if enabled {
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
    }

    func startAutoRefresh() {
        autoRefresh?.start(interval: autoRefreshInterval)
    }

    func stopAutoRefresh() {
        autoRefresh?.stop()
    }

    private func fetchAll() async {
        guard isConfigured else { return }

        isLoading = true
        errorMessage = nil

        do {
            let quota = try await ZaiAPIService.shared.fetchQuotaLimits()
            let usage = try await ZaiAPIService.shared.fetchModelUsage(range: selectedRange)
            quotaLimits = quota
            modelUsage = usage
            lastFetchedAt = Date()
            errorMessage = nil
            ZaiAPIService.shared.saveToCache(quota: quota, modelUsage: usage)
            await updateResetReminderState()
        } catch {
            errorMessage = error.localizedDescription
            if quotaLimits == nil { loadCache() }
        }

        isLoading = false
    }

    // MARK: - Computed

    var maxQuotaPercent: Double {
        quotaLimits?.map(\.percentage).max() ?? 0
    }

    var fiveHourPercent: Double? {
        quotaLimits?.first(where: { $0.kind == .fiveHours })?.percentage
    }

    var tokenQuotaLimits: [ZaiQuotaLimitDisplay] {
        quotaLimits?.filter(\.kind.isTokenLimit) ?? []
    }

    var toolQuotaLimit: ZaiQuotaLimitDisplay? {
        quotaLimits?.first(where: { $0.kind == .monthlySearch })
    }

    private func updateResetReminderState() async {
        let fiveHourLimit = quotaLimits?.first(where: { $0.kind == .fiveHours })
        await UsageResetNotificationService.shared.updateReminder(
            provider: .zai,
            utilization: fiveHourLimit?.percentage,
            resetAt: fiveHourLimit?.nextResetDate,
            fetchedAt: lastFetchedAt
        )
    }
}
