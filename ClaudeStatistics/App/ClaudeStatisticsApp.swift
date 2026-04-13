import SwiftUI
import Combine
import TelemetryDeck

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var providerKind: ProviderKind
    @Published private(set) var store: SessionDataStore
    @Published private(set) var sessionViewModel: SessionViewModel
    let usageViewModel = UsageViewModel()
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let selectedKind = ProviderRegistry.selectedProviderKind()
        providerKind = selectedKind
        let provider = ProviderRegistry.provider(for: selectedKind)
        let store = SessionDataStore(provider: provider)
        self.store = store
        self.sessionViewModel = SessionViewModel(store: store)
        store.start()
        usageViewModel.store = store
        configureUsageState(for: provider)

        // Sync subscription weekly reset date to SessionDataStore
        usageViewModel.$usageData
            .map { $0?.sevenDay?.resetsAtDate }
            .removeDuplicates()
            .sink { [weak self] resetDate in
                self?.store.weeklyResetDate = resetDate
            }
            .store(in: &cancellables)
    }

    var provider: any SessionProvider { store.provider }
    var providerCapabilities: ProviderCapabilities { provider.capabilities }
    var menuBarText: String { providerCapabilities.supportsUsageWindows ? usageViewModel.menuBarText : "" }

    func switchProvider(to kind: ProviderKind) {
        guard kind != providerKind else { return }

        store.stop()
        ProviderRegistry.persistSelectedProvider(kind)
        providerKind = kind

        let provider = ProviderRegistry.provider(for: kind)
        let nextStore = SessionDataStore(provider: provider)
        nextStore.weeklyResetDate = usageViewModel.usageData?.sevenDay?.resetsAtDate
        nextStore.start()

        store = nextStore
        sessionViewModel = SessionViewModel(store: nextStore)
        usageViewModel.store = nextStore
        configureUsageState(for: provider)
    }

    private func configureUsageState(for provider: any SessionProvider) {
        usageViewModel.configure(source: provider.usageSource)
        configureProfileLoader(for: provider)
        if provider.capabilities.supportsUsageWindows {
            usageViewModel.loadCache()
            if UserDefaults.standard.bool(forKey: "autoRefreshEnabled") {
                usageViewModel.startAutoRefresh()
            }
        } else {
            usageViewModel.clearForUnsupportedProvider()
        }
    }

    private func configureProfileLoader(for provider: any SessionProvider) {
        profileViewModel.configure(loader: { await provider.fetchProfile() })
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = TelemetryDeck.Config(appID: "C5662554-D78C-4334-A745-3661642DBE3D")
        TelemetryDeck.initialize(config: config)

        LanguageManager.setup()
        statusBarController = StatusBarController(appState: appState)
    }
}

@main
struct ClaudeStatisticsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scene — everything is managed by StatusBarController
        Settings { EmptyView() }
    }
}
