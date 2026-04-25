import SwiftUI
import Combine
import TelemetryDeck

private enum DefaultSettings {
    static func register() {
        UserDefaults.standard.register(defaults: AppPreferences.registeredDefaults)
        MenuBarPreferences.register()
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
    /// Per-provider usage view models for providers that are *not* currently
    /// selected. Keeps the menu bar strip able to show every enabled
    /// provider's usage without interfering with `usageViewModel`'s single
    /// active-provider contract. The current provider is always served via
    /// `usageViewModel` (see `usageViewModel(for:)`).
    @Published private(set) var secondaryUsageViewModels: [ProviderKind: UsageViewModel] = [:]
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    let notchCenter = NotchNotificationCenter()
    lazy var activeSessionsTracker = ActiveSessionsTracker()
    let claudeAccountManager = ClaudeAccountManager()
    let independentClaudeAccountManager = IndependentClaudeAccountManager()
    let codexAccountManager = CodexAccountManager()
    let geminiAccountManager = GeminiAccountManager()
    private var cancellables: Set<AnyCancellable> = []
    private var runtimeBridgeCancellables: [ProviderKind: AnyCancellable] = [:]
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

        for kind in startupKinds {
            if let store = storesByProvider[kind] {
                bindRuntimeBridge(for: kind, store: store)
            }
        }

        // Sync subscription weekly reset date to SessionDataStore
        usageViewModel.$usageData
            .map { $0?.sevenDay?.resetsAtDate }
            .removeDuplicates()
            .sink { [weak self] resetDate in
                self?.store.weeklyResetDate = resetDate
            }
            .store(in: &cancellables)

        // Boot one independent UsageViewModel per non-current startup provider
        // so the menu bar can display all enabled providers' usage in
        // parallel, using the same refresh cadence as the single-provider
        // path.
        for kind in startupKinds where kind != selectedKind {
            secondaryUsageViewModels[kind] = makeSecondaryUsageViewModel(for: kind)
        }
    }

    /// VM getter that maps a provider kind to its live UsageViewModel.
    /// Current provider → the primary `usageViewModel` singleton;
    /// others → the per-provider secondary VMs.
    func usageViewModel(for kind: ProviderKind) -> UsageViewModel? {
        if kind == providerKind { return usageViewModel }
        return secondaryUsageViewModels[kind]
    }

    private func makeSecondaryUsageViewModel(for kind: ProviderKind) -> UsageViewModel {
        let vm = UsageViewModel()
        guard let store = storesByProvider[kind] else { return vm }
        vm.store = store
        let provider = ProviderRegistry.provider(for: kind)
        vm.configure(source: provider.usageSource, usagePresentation: provider.usagePresentation)
        if provider.capabilities.supportsUsage {
            vm.loadCache()
            if UserDefaults.standard.bool(forKey: AppPreferences.autoRefreshEnabled) {
                vm.startAutoRefresh()
            }
        } else {
            vm.clearForUnsupportedProvider()
        }
        vm.$usageData
            .map { $0?.sevenDay?.resetsAtDate }
            .removeDuplicates()
            .sink { [weak self] resetDate in
                self?.storesByProvider[kind]?.weeklyResetDate = resetDate
            }
            .store(in: &cancellables)
        return vm
    }

    var provider: any SessionProvider { store.provider }
    var providerCapabilities: ProviderCapabilities { provider.capabilities }
    var menuBarText: String { providerCapabilities.supportsUsage ? usageViewModel.menuBarText : "" }

    func switchProvider(to kind: ProviderKind) {
        guard kind != providerKind else { return }
        let available = ProviderRegistry.availableProviders()
        guard available.isEmpty || available.contains(kind) else { return }

        let oldKind = providerKind

        ProviderRegistry.persistSelectedProvider(kind)
        providerKind = kind

        let context = ensureProviderContext(for: kind)
        let nextStore = context.store
        nextStore.weeklyResetDate = usageViewModel.usageData?.sevenDay?.resetsAtDate

        store = nextStore
        sessionViewModel = context.viewModel
        usageViewModel.store = nextStore
        configureUsageState(for: nextStore.provider)

        // Promote the incoming kind out of the secondary pool (it is now
        // served by the primary `usageViewModel`) and demote the outgoing
        // kind into the secondary pool so the menu bar strip keeps its
        // usage fresh in the background.
        if let promoted = secondaryUsageViewModels.removeValue(forKey: kind) {
            promoted.stopAutoRefresh()
        }
        if storesByProvider[oldKind] != nil {
            secondaryUsageViewModels[oldKind] = makeSecondaryUsageViewModel(for: oldKind)
        }

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
        for vm in secondaryUsageViewModels.values {
            vm.stopAutoRefresh()
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

    func restoreNotchRuntime(for providers: [ProviderKind]) {
        for kind in providers {
            let store = storesByProvider[kind]
            let sessions = store?.sessions
            let restoredSource: [Session]
            if let sessions, !sessions.isEmpty {
                restoredSource = sessions
            } else {
                restoredSource = ProviderRegistry.provider(for: kind).scanSessions()
            }
            // Feed stats into the restore so the triptych has real text on the
            // first render. Without this, the runtime copy is shell-only and
            // the UI shows "No prompt yet / Idle / Waiting for input" until
            // the first syncTranscriptSignals debounce fires.
            activeSessionsTracker.restoreRuntime(
                for: kind,
                sessions: restoredSource,
                quickStats: store?.quickStats ?? [:],
                parsedStats: store?.parsedStats ?? [:]
            )
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
        bindRuntimeBridge(for: kind, store: rebuiltStore)

        if providerKind == kind {
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
        } else {
            // Non-current provider — rebuild its secondary VM so the menu bar
            // strip reflects the account change.
            if let old = secondaryUsageViewModels.removeValue(forKey: kind) {
                old.stopAutoRefresh()
            }
            secondaryUsageViewModels[kind] = makeSecondaryUsageViewModel(for: kind)
        }
    }

    func rebuildSessionCache(for kind: ProviderKind) {
        let context = ensureProviderContext(for: kind)
        context.viewModel.selectedSession = nil
        context.viewModel.selectedSessionStats = nil
        context.viewModel.showTranscript = false
        context.store.forceRescan()

        if providerKind == kind {
            store = context.store
            sessionViewModel = context.viewModel
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
            if UserDefaults.standard.bool(forKey: AppPreferences.autoRefreshEnabled) {
                usageViewModel.startAutoRefresh()
            }
        } else {
            usageViewModel.clearForUnsupportedProvider()
        }
    }

    private func configureProfileLoader(for provider: any AccountProvider) {
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
        bindRuntimeBridge(for: kind, store: store)
        return (store, viewModel)
    }

    private func bindRuntimeBridge(for kind: ProviderKind, store: SessionDataStore) {
        runtimeBridgeCancellables[kind]?.cancel()

        guard kind == .codex else {
            runtimeBridgeCancellables[kind] = nil
            return
        }

        runtimeBridgeCancellables[kind] = Publishers.CombineLatest3(
            store.$sessions,
            store.$quickStats,
            store.$parsedStats
        )
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] sessions, quickStats, parsedStats in
            guard let self, NotchPreferences.isEnabled(kind) else { return }
            self.activeSessionsTracker.syncTranscriptSignals(
                provider: kind,
                sessions: sessions,
                quickStats: quickStats,
                parsedStats: parsedStats
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    let appState = AppState()
    private var notchBridge: AttentionBridge?
    private var notchWindowController: NotchWindowController?
    private var notchStateObserver: NSObjectProtocol?
    private var lastEnabledNotchProviders: Set<ProviderKind>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app + local socket bridge + pending approval state means we
        // should stay alive even when there is no key window. Letting AppKit's
        // automatic termination reclaim us breaks in-flight hook responses.
        let processInfo = ProcessInfo.processInfo
        processInfo.disableAutomaticTermination("Claude Statistics maintains background CLI integrations")
        processInfo.disableSuddenTermination()

        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let executablePath = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "unknown"
        DiagnosticLogger.shared.appProcessStarted(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: bundleID,
            executablePath: executablePath
        )

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
        // Silently register this bundle id with TCC. Without this, ad-hoc
        // signed debug builds never appear in System Settings → Privacy &
        // Security → Accessibility at all — TCC only learns about the app
        // after a prompt, and a silent CGEventTap probe that *fails* doesn't
        // count. Passing prompt=false adds the entry with its switch off so
        // the user can flip it themselves without a popup.
        AccessibilityPermissionSupport.registerVisibility(prompt: false)

        // Debug builds (different bundle id) need a manual nudge: if the
        // silent register above didn't stick, fire the prompt once. This is
        // conditional on the debug bundle id to avoid bothering release
        // users — they got their permissions through a previous install.
        let isDebugBundle = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".debug")
        if isDebugBundle, !AXIsProcessTrusted() {
            let key = "debug.accessibility.promptShown"
            let shown = UserDefaults.standard.bool(forKey: key)
            if !shown {
                // LSUIElement apps don't get the prompt dialog unless we force
                // them to the front. Activate, prompt, then let the app drop
                // back to being a menu-bar resident on its own.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    AccessibilityPermissionSupport.registerVisibility(prompt: true)
                    UserDefaults.standard.set(true, forKey: key)
                    // Restore menu-bar-only policy after the prompt has fired.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }

        // If the user has already granted access, probe a tap once so macOS
        // wires up the permission for this launch without waiting for the
        // first keyboard interception.
        AccessibilityPermissionSupport.registerViaEventTapProbe()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLogger.shared.appProcessWillTerminate(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown"
        )
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

        let enabledProviders = Set(ProviderRegistry.supportedProviders.filter {
            NotchPreferences.isEnabled($0)
        })
        let disabledProviders = ProviderRegistry.supportedProviders.filter {
            !enabledProviders.contains($0)
        }
        let providersToRestore = lastEnabledNotchProviders.map {
            Array(enabledProviders.subtracting($0))
        } ?? Array(enabledProviders)

        appState.purgeNotchRuntime(for: disabledProviders)
        reconcileNotchStack()
        if !providersToRestore.isEmpty {
            appState.restoreNotchRuntime(for: providersToRestore)
        }
        appState.refreshNotchActiveSessionsIfEnabled()
        lastEnabledNotchProviders = enabledProviders
    }

    private func handleNotchStateChanged() {
        applyNotchProviderPreferences()
    }
}

struct ClaudeStatisticsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scene — everything is managed by StatusBarController
        Settings { EmptyView() }
    }
}
