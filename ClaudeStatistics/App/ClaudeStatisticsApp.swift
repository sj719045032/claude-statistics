import SwiftUI
import Combine
import TelemetryDeck

private enum DefaultSettings {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "autoRefreshEnabled": true,
            "refreshInterval": 300.0
        ])
    }
}

private enum StatusLineSync {
    static func refreshManagedIntegrations() {
        for kind in ProviderRegistry.supportedProviders {
            let provider = ProviderRegistry.provider(for: kind)
            guard let installer = provider.statusLineInstaller, installer.isInstalled else { continue }
            try? installer.install()
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var providerKind: ProviderKind
    @Published private(set) var store: SessionDataStore
    @Published private(set) var sessionViewModel: SessionViewModel
    @Published private(set) var isPopoverVisible = false
    let usageViewModel = UsageViewModel()
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    let notchCenter = NotchNotificationCenter()
    lazy var activeSessionsTracker = ActiveSessionsTracker { [weak self] in
        guard let self else { return [] }
        return self.collectActiveSessions()
    }
    let claudeAccountManager = ClaudeAccountManager()
    let independentClaudeAccountManager = IndependentClaudeAccountManager()
    let codexAccountManager = CodexAccountManager()
    let geminiAccountManager = GeminiAccountManager()
    private var cancellables: Set<AnyCancellable> = []
    private var activeSessionRefreshCancellables: [ProviderKind: Set<AnyCancellable>] = [:]
    private var storesByProvider: [ProviderKind: SessionDataStore] = [:]
    private var sessionViewModelsByProvider: [ProviderKind: SessionViewModel] = [:]

    init() {
        DefaultSettings.register()
        StatusLineSync.refreshManagedIntegrations()

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

        for (kind, store) in storesByProvider {
            bindActiveSessionRefresh(for: kind, store: store)
        }

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

    func purgeNotchRuntime(for providers: [ProviderKind]) {
        for kind in providers {
            notchCenter.purgeProvider(kind)
            activeSessionsTracker.purgeRuntime(for: kind)
        }
    }

    func refreshNotchActiveSessionsIfEnabled() {
        if NotchPreferences.anyProviderEnabled {
            activeSessionsTracker.refresh()
        }
    }

    func refreshProviderAfterAccountChange(_ kind: ProviderKind) {
        switch kind {
        case .claude:
            claudeAccountManager.load()
            independentClaudeAccountManager.load()
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
        bindActiveSessionRefresh(for: kind, store: rebuiltStore)

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

    fileprivate func collectActiveSessions() -> [ActiveSession] {
        func newestText(
            parsedText: String?,
            parsedAt: Date?,
            quickText: String?,
            quickAt: Date?
        ) -> (text: String?, at: Date?) {
            guard parsedText != nil || quickText != nil else { return (nil, nil) }

            switch (parsedAt, quickAt) {
            case let (p?, q?) where q > p:
                return (quickText ?? parsedText, q)
            case let (p?, _):
                return (parsedText ?? quickText, p)
            case (nil, let q?):
                return (quickText ?? parsedText, q)
            case (nil, nil):
                return (parsedText ?? quickText, nil)
            }
        }

        func newestTool(
            parsed: SessionStats?,
            quick: SessionQuickStats?
        ) -> (name: String?, summary: String?, detail: String?, at: Date?) {
            guard parsed?.lastToolSummary != nil || quick?.lastToolSummary != nil else {
                return (nil, nil, nil, nil)
            }

            switch (parsed?.lastToolAt, quick?.lastToolAt) {
            case let (p?, q?) where q > p:
                return (quick?.lastToolName, quick?.lastToolSummary, quick?.lastToolDetail, q)
            case let (p?, _):
                return (parsed?.lastToolName, parsed?.lastToolSummary, parsed?.lastToolDetail, p)
            case (nil, let q?):
                return (quick?.lastToolName, quick?.lastToolSummary, quick?.lastToolDetail, q)
            case (nil, nil):
                if let parsed, parsed.lastToolSummary != nil {
                    return (parsed.lastToolName, parsed.lastToolSummary, parsed.lastToolDetail, nil)
                }
                return (quick?.lastToolName, quick?.lastToolSummary, quick?.lastToolDetail, nil)
            }
        }

        var result: [ActiveSession] = []
        for (kind, store) in storesByProvider {
            guard NotchPreferences.isEnabled(kind) else { continue }
            for s in store.sessions {
                let parsed = store.parsedStats[s.id]
                let quick = store.quickStats[s.id]
                let latestPrompt = newestText(
                    parsedText: parsed?.lastPrompt,
                    parsedAt: parsed?.lastPromptAt,
                    quickText: quick?.lastPrompt,
                    quickAt: quick?.lastPromptAt
                )
                let latestPreview = newestText(
                    parsedText: parsed?.lastOutputPreview,
                    parsedAt: parsed?.lastOutputPreviewAt,
                    quickText: quick?.lastOutputPreview,
                    quickAt: quick?.lastOutputPreviewAt
                )
                let latestTool = newestTool(parsed: parsed, quick: quick)

                var active = ActiveSession(
                    id: s.id,
                    sessionId: s.externalID,
                    provider: kind,
                    projectName: s.displayName,
                    projectPath: s.cwd ?? s.projectPath,
                    currentActivity: latestTool.summary,
                    latestPrompt: latestPrompt.text,
                    latestPromptAt: latestPrompt.at,
                    latestPreview: latestPreview.text,
                    latestPreviewAt: latestPreview.at,
                    lastActivityAt: latestTool.at ?? latestPreview.at ?? latestPrompt.at ?? s.lastModified,
                    tty: nil,
                    pid: nil,
                    terminalName: nil,
                    terminalSocket: nil,
                    terminalWindowID: nil,
                    terminalTabID: nil,
                    terminalStableID: nil
                )
                active.currentToolName = latestTool.name
                active.currentToolDetail = latestTool.detail
                if latestTool.at != nil {
                    active.status = .running
                }
                result.append(active)
            }
        }
        return result
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
        bindActiveSessionRefresh(for: kind, store: store)
        return (store, viewModel)
    }

    private func bindActiveSessionRefresh(for kind: ProviderKind, store: SessionDataStore) {
        activeSessionRefreshCancellables[kind]?.forEach { $0.cancel() }

        var bag = Set<AnyCancellable>()
        Publishers.Merge3(
            store.$sessions.map { _ in () }.eraseToAnyPublisher(),
            store.$quickStats.map { _ in () }.eraseToAnyPublisher(),
            store.$parsedStats.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            self?.activeSessionsTracker.refresh()
        }
        .store(in: &bag)

        activeSessionRefreshCancellables[kind] = bag
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    let appState = AppState()
    private var notchBridge: AttentionBridge?
    private var notchWindowController: NotchWindowController?
    private var notchStateObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = TelemetryDeck.Config(appID: "C5662554-D78C-4334-A745-3661642DBE3D")
        TelemetryDeck.initialize(config: config)

        LanguageManager.setup()
        NotchPreferences.migrateLegacyIfNeeded()

        statusBarController = StatusBarController(appState: appState) { [weak self] in
            self?.handleIslandShortcut() ?? false
        }
        appState.notchCenter.activeSessionsTracker = appState.activeSessionsTracker

        applyNotchProviderPreferences()

        // Register with TCC so this build shows up in System Settings →
        // Accessibility without the user having to invoke a keyboard-captured
        // action first. Creating a CGEventTap — even one we immediately
        // throw away — is enough to make the entry appear (separate entries
        // for Release and Debug since their bundle IDs differ). This stays
        // silent: no system prompt, no UI disruption.
        Self.registerForAccessibilityVisibility()

        notchStateObserver = NotificationCenter.default.addObserver(
            forName: NotchPreferences.stateChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleNotchStateChanged() }
        }
    }

    private static func registerForAccessibilityVisibility() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let noopCallback: CGEventTapCallBack = { _, _, event, _ in
            Unmanaged.passUnretained(event)
        }
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: noopCallback,
            userInfo: nil
        ) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopAllStores()
        notchBridge?.stop()
        if let notchStateObserver {
            NotificationCenter.default.removeObserver(notchStateObserver)
        }
    }

    /// Spin up bridge + tracker + window only when at least one provider is
    /// enabled; tear them all down once every provider is off. Idempotent.
    private func reconcileNotchStack() {
        if NotchPreferences.anyProviderEnabled {
            if notchBridge == nil {
                let bridge = AttentionBridge()
                bridge.notchCenter = appState.notchCenter
                bridge.start()
                notchBridge = bridge
            }
            appState.activeSessionsTracker.start()
            if notchWindowController == nil {
                notchWindowController = NotchWindowController(
                    notchCenter: appState.notchCenter,
                    activeTracker: appState.activeSessionsTracker
                )
            }
        } else {
            notchBridge?.stop()
            notchBridge = nil
            appState.activeSessionsTracker.stop()
            notchWindowController?.close()
            notchWindowController = nil
        }
    }

    private func handleIslandShortcut() -> Bool {
        guard NotchPreferences.anyProviderEnabled else { return false }
        guard NotchPreferences.keyboardControlsEnabled else { return false }
        reconcileNotchStack()
        guard let notchWindowController else { return false }
        notchWindowController.toggleIdlePeekFromShortcut()
        return true
    }

    /// Single app-level reconciliation point for per-provider notch switches.
    /// Providers declare hook/install capabilities; the app owns global runtime
    /// effects such as active cards, the socket bridge, and the island window.
    private func applyNotchProviderPreferences() {
        Task { _ = try? await NotchHookSync.syncCurrent() }

        let disabledProviders = ProviderRegistry.supportedProviders.filter {
            !NotchPreferences.isEnabled($0)
        }
        appState.purgeNotchRuntime(for: disabledProviders)
        reconcileNotchStack()
        appState.refreshNotchActiveSessionsIfEnabled()
    }

    private func handleNotchStateChanged() {
        applyNotchProviderPreferences()
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
