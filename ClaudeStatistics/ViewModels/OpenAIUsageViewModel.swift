import Combine
import Foundation

@MainActor
final class OpenAIUsageViewModel: ObservableObject {
    @Published private(set) var authState: OpenAIAuthState = OpenAIAuthState(
        status: .notFound,
        accountId: nil,
        accountEmail: nil,
        accessToken: nil,
        refreshToken: nil,
        idToken: nil
    )
    @Published var usageData: OpenAIUsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var autoRefreshInterval: TimeInterval = 300

    private let service: OpenAIUsageServicing
    private var autoRefresh: AutoRefreshCoordinator?
    private var didSetup = false

    init(service: OpenAIUsageServicing = OpenAIUsageAPIService.shared) {
        self.service = service

        autoRefresh = AutoRefreshCoordinator { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    func setup() {
        guard !didSetup else { return }
        didSetup = true

        authState = service.authState
        loadCache()

        if !authState.isConfigured {
            errorMessage = OpenAIUsageError.notConfigured(authState.status).localizedDescription
        }

        let enabled = UserDefaults.standard.bool(forKey: "autoRefreshEnabled")
            && UserDefaults.standard.bool(forKey: "openAIUsageEnabled")
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        applyAutoRefreshSettings(enabled: enabled, interval: interval)

        if enabled && authState.isConfigured {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func loadCache() {
        guard let cached = service.loadCache() else { return }
        usageData = cached.data
        lastFetchedAt = cached.fetchedAt
    }

    func refresh() async {
        await fetchUsage(clearError: false)
    }

    func forceRefresh() async {
        await fetchUsage(clearError: true)
    }

    func refreshAuthState() {
        syncAuthState()
        if !authState.isConfigured {
            errorMessage = OpenAIUsageError.notConfigured(authState.status).localizedDescription
        }
    }

    func applyAutoRefreshSettings(enabled: Bool, interval: TimeInterval) {
        autoRefreshInterval = interval > 0 ? interval : 300

        guard authState.isConfigured else {
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

    var currentWindowPercent: Double? {
        usageData?.currentWindow?.utilization
    }

    var weeklyPercent: Double? {
        usageData?.weeklyWindow?.utilization
    }

    var currentWindowResetCountdown: String? {
        countdownString(for: usageData?.currentWindow?.resetAt)
    }

    var weeklyResetCountdown: String? {
        countdownString(for: usageData?.weeklyWindow?.resetAt)
    }

    var hasDisplayableUsage: Bool {
        currentWindowPercent != nil || weeklyPercent != nil || isLoading
    }

    var isConfigured: Bool {
        authState.isConfigured
    }

    private func fetchUsage(clearError: Bool) async {
        syncAuthState()

        guard authState.isConfigured else {
            errorMessage = OpenAIUsageError.notConfigured(authState.status).localizedDescription
            stopAutoRefresh()
            return
        }

        isLoading = true
        if clearError {
            errorMessage = nil
        }

        do {
            let data = try await service.fetchUsage()
            usageData = data
            lastFetchedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if usageData == nil {
                loadCache()
            }
        }

        syncAuthState()
        isLoading = false
    }

    private func syncAuthState() {
        authState = service.authState
        if !authState.isConfigured {
            stopAutoRefresh()
        }
    }

    private func countdownString(for date: Date?) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "已重置" }

        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
