import Foundation
import SwiftUI

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var autoRefreshInterval: TimeInterval = 300
    @Published var userProfile: UserProfile?
    @Published var profileLoading = false

    private var refreshTask: Task<Void, Never>?
    private var activeInterval: TimeInterval = 0

    init() {
        loadCache()
        let enabled = UserDefaults.standard.bool(forKey: "autoRefreshEnabled")
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        if enabled {
            autoRefreshInterval = interval > 0 ? interval : 300
            Task { @MainActor in
                await self.refresh()
            }
            startAutoRefresh()
        }
        // Load profile once on startup
        Task { @MainActor in
            await self.loadProfile()
        }
    }

    func loadProfile() async {
        guard userProfile == nil, !profileLoading else { return }
        guard CredentialService.shared.getAccessToken() != nil else { return }
        profileLoading = true
        do {
            userProfile = try await UsageAPIService.shared.fetchProfile()
        } catch {
            // Silent fail — settings will show token-only fallback
        }
        profileLoading = false
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
        let interval = autoRefreshInterval
        // Don't restart if already running with the same interval
        if refreshTask != nil && activeInterval == interval {
            return
        }
        stopAutoRefresh()
        activeInterval = interval
        refreshTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
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
