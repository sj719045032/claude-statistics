import SwiftUI
import Combine
import TelemetryDeck

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var providerKind: ProviderKind
    @Published private(set) var store: SessionDataStore
    @Published private(set) var sessionViewModel: SessionViewModel
    @Published private(set) var isPopoverVisible = false
    let usageViewModel = UsageViewModel()
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    let claudeAccountManager = ClaudeAccountManager()
    let codexAccountManager = CodexAccountManager()
    let geminiAccountManager = GeminiAccountManager()
    private var cancellables: Set<AnyCancellable> = []
    private var storesByProvider: [ProviderKind: SessionDataStore] = [:]
    private var sessionViewModelsByProvider: [ProviderKind: SessionViewModel] = [:]

    init() {
        let selectedKind = ProviderRegistry.selectedProviderKind()
        providerKind = selectedKind
        let availableKinds = Set(ProviderRegistry.availableProviders())
        let startupKinds = ProviderRegistry.supportedProviders.filter { kind in
            availableKinds.contains(kind) || kind == selectedKind
        }

        var storesByProvider: [ProviderKind: SessionDataStore] = [:]
        var sessionViewModelsByProvider: [ProviderKind: SessionViewModel] = [:]
        for kind in startupKinds {
            let provider = ProviderRegistry.provider(for: kind)
            let store = SessionDataStore(provider: provider)
            let viewModel = SessionViewModel(store: store)
            storesByProvider[kind] = store
            sessionViewModelsByProvider[kind] = viewModel
            store.start()
        }

        self.storesByProvider = storesByProvider
        self.sessionViewModelsByProvider = sessionViewModelsByProvider

        let store = storesByProvider[selectedKind]!
        self.store = store
        self.sessionViewModel = sessionViewModelsByProvider[selectedKind]!
        usageViewModel.store = store
        configureUsageState(for: store.provider)

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
    var menuBarText: String { providerCapabilities.supportsUsage ? usageViewModel.menuBarText : "" }

    func switchProvider(to kind: ProviderKind) {
        guard kind != providerKind else { return }
        let available = ProviderRegistry.availableProviders()
        guard available.isEmpty || available.contains(kind) else { return }

        ProviderRegistry.persistSelectedProvider(kind)
        providerKind = kind

        let context = ensureProviderContext(for: kind)
        let nextStore = context.store
        nextStore.weeklyResetDate = usageViewModel.usageData?.sevenDay?.resetsAtDate

        store = nextStore
        sessionViewModel = context.viewModel
        usageViewModel.store = nextStore
        configureUsageState(for: nextStore.provider)

        if isPopoverVisible {
            nextStore.popoverDidOpen()
        }
    }

    func popoverDidOpen() {
        isPopoverVisible = true
        store.popoverDidOpen()
    }

    func popoverDidClose() {
        isPopoverVisible = false
        store.popoverDidClose()
    }

    func stopAllStores() {
        for store in storesByProvider.values {
            store.stop()
        }
    }

    func refreshProviderAfterAccountChange(_ kind: ProviderKind) {
        switch kind {
        case .claude:
            claudeAccountManager.load()
        case .codex:
            codexAccountManager.load()
        case .gemini:
            geminiAccountManager.load()
        }

        if let existingStore = storesByProvider[kind] {
            existingStore.stop()
        }

        let provider = ProviderRegistry.provider(for: kind)
        let rebuiltStore = SessionDataStore(provider: provider)
        let rebuiltViewModel = SessionViewModel(store: rebuiltStore)
        storesByProvider[kind] = rebuiltStore
        sessionViewModelsByProvider[kind] = rebuiltViewModel
        rebuiltStore.start()

        guard providerKind == kind else { return }

        store = rebuiltStore
        sessionViewModel = rebuiltViewModel
        usageViewModel.store = rebuiltStore
        configureUsageState(for: provider)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.profileViewModel.forceRefresh()
            await self.usageViewModel.forceRefresh()
        }

        if isPopoverVisible {
            rebuiltStore.popoverDidOpen()
        }
    }

    func buildAllProvidersShareRoleResult() -> ShareRoleResult? {
        let availableKinds = ProviderRegistry.availableProviders()
        let stores = availableKinds.map { ensureProviderContext(for: $0).store }
        let scopeLabel = LanguageManager.localizedString("share.scope.allProviders")
        let metrics = stores.compactMap { store in
            store.buildAllTimeShareMetrics(scopeLabel: scopeLabel)
        }
        guard !metrics.isEmpty else { return nil }

        let end = Date()
        let start = metrics.map(\.period.start).min() ?? end
        guard let mergedMetrics = ShareMetricsBuilder.merge(
            metrics,
            scope: .all,
            scopeLabel: scopeLabel,
            period: DateInterval(start: start, end: end)
        ) else {
            return nil
        }

        let baselineMetrics = stores.compactMap { store in
            store.buildAllTimeShareBaselineMetrics(end: end)
        }
        let baselineStart = Calendar.current.date(byAdding: .day, value: -365, to: end) ?? end
        let mergedBaseline = ShareMetricsBuilder.merge(
            baselineMetrics,
            scope: .all,
            scopeLabel: LanguageManager.localizedString("share.scope.lastYear"),
            period: DateInterval(start: baselineStart, end: end)
        )
        return ShareRoleEngine.makeAllTimeRoleResult(metrics: mergedMetrics, baseline: mergedBaseline)
    }

    private func configureUsageState(for provider: any SessionProvider) {
        usageViewModel.configure(source: provider.usageSource, usagePresentation: provider.usagePresentation)
        configureProfileLoader(for: provider)
        if provider.capabilities.supportsUsage {
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

    @discardableResult
    private func ensureProviderContext(for kind: ProviderKind) -> (store: SessionDataStore, viewModel: SessionViewModel) {
        if let store = storesByProvider[kind], let viewModel = sessionViewModelsByProvider[kind] {
            return (store, viewModel)
        }

        let provider = ProviderRegistry.provider(for: kind)
        let store = SessionDataStore(provider: provider)
        let viewModel = SessionViewModel(store: store)
        storesByProvider[kind] = store
        sessionViewModelsByProvider[kind] = viewModel
        store.start()
        return (store, viewModel)
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

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopAllStores()
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
