import SwiftUI
import Combine
import TelemetryDeck
import ClaudeStatisticsKit

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
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    let notchCenter = NotchNotificationCenter()
    let activeSessionsTracker: ActiveSessionsTracker
    let accounts = AccountManagers()
    let providerContexts: ProviderContextRegistry
    let usageVMs: UsageVMRegistry
    let notchRuntime: NotchRuntimeCoordinator

    /// Stage-3D dogfood: the v4.0 plugin registry runs alongside the
    /// legacy `ProviderRegistry` / `TerminalRegistry` (which still drive
    /// the kernel's switch-based dispatch). Stage 4 migrates the kernel
    /// over and the legacy registries are retired. All 11 builtin
    /// plugins (3 Provider + 8 Terminal) register here as an end-to-end
    /// smoke test of the registration path; share-card role/theme
    /// plugins land in stage 4.
    let pluginRegistry: PluginRegistry = {
        let registry = PluginRegistry()
        let plugins: [any Plugin] = [
            ClaudePluginDogfood(),
            CodexPluginDogfood(),
            GeminiPluginDogfood(),
            AlacrittyPlugin(),
            ITermPlugin(),
            AppleTerminalPlugin(),
            GhosttyPlugin(),
            KittyPlugin(),
            WezTermPlugin(),
            WarpPlugin(),
            EditorPlugin()
        ]
        for plugin in plugins {
            do {
                try registry.register(plugin)
            } catch {
                DiagnosticLogger.shared.warning(
                    "PluginRegistry dogfood register failed for \(type(of: plugin)): \(error)"
                )
            }
        }
        // Discover .csplugin bundles. Bundled samples live in
        // Contents/PlugIns (shipped inside the .app, implicitly trusted);
        // user-installed plugins live under
        // ~/Library/Application Support/Claude Statistics/Plugins and
        // are gated by `PluginTrustGate`: previously-allowed plugins
        // load, previously-denied plugins are skipped, and unknown
        // plugins are queued for the post-launch NSAlert prompt.
        if let pluginsDir = Bundle.main.builtInPlugInsURL {
            let report = PluginLoader.loadAll(
                from: pluginsDir,
                into: registry,
                trustEvaluator: { _, _ in true }
            )
            DiagnosticLogger.shared.info(
                "PluginLoader (bundled): loaded=\(report.loaded.count) skipped=\(report.skipped.count)"
            )
            for skip in report.skipped {
                DiagnosticLogger.shared.warning(
                    "PluginLoader skipped \(skip.url.lastPathComponent): \(skip.reason)"
                )
            }
        }
        let userReport = PluginLoader.loadAll(
            from: PluginLoader.defaultDirectory,
            into: registry,
            trustEvaluator: PluginTrustGate.evaluate
        )
        DiagnosticLogger.shared.info(
            "PluginLoader (user): loaded=\(userReport.loaded.count) skipped=\(userReport.skipped.count) pending=\(PluginTrustGate.snapshotPending().count)"
        )
        AppState.refreshDynamicTerminalRegistries(from: registry)
        DiagnosticLogger.shared.info(
            "PluginRegistry dogfood: providers=\(registry.providers.count) terminals=\(registry.terminals.count)"
        )
        return registry
    }()

    /// Teach `TerminalRegistry` about every terminal plugin's bundle
    /// ids and `terminalNameAliases`. Bundle ids let `ProcessTreeWalker`
    /// accept external plugins (e.g. the chat-app plugins above) as focus
    /// targets while ascending the parent process chain. Alias mappings
    /// let `bundleId(forTerminalName:)` resolve hook `terminal_name`
    /// strings (e.g. "claude", "codex") to the plugin's bundle id when
    /// no host-side `TerminalCapability` claims that name. Builtin
    /// identifiers/aliases are also covered by `appCapabilities`; the
    /// union here is harmless.
    ///
    /// Idempotent — `TerminalRegistry`'s dynamic stores accumulate, so
    /// the hot-load path can call this again after registering a new
    /// plugin without dropping anything that was already known.
    static func refreshDynamicTerminalRegistries(from registry: PluginRegistry) {
        var pluginBundleIds: Set<String> = []
        var pluginNameAliases: [String: String] = [:]
        for plugin in registry.terminals.values {
            guard let terminal = plugin as? any TerminalPlugin else { continue }
            let descriptor = terminal.descriptor
            guard let primaryBundleId = descriptor.bundleIdentifiers.sorted().first else { continue }
            pluginBundleIds.formUnion(descriptor.bundleIdentifiers)
            for alias in descriptor.terminalNameAliases {
                pluginNameAliases[alias] = primaryBundleId
            }
        }
        TerminalRegistry.registerDynamicBundleIdentifiers(pluginBundleIds)
        TerminalRegistry.registerDynamicTerminalNames(pluginNameAliases)
    }

    /// Caches every `ProviderPlugin.makeProvider()` result into
    /// `ProviderRegistry`'s dynamic store so `provider(for:)` prefers
    /// plugin-supplied instances over the legacy `switch`. Builtin
    /// dogfood wrappers return the existing `*.shared` singletons so
    /// this is behaviour-preserving today; once bundle loading lands in
    /// M2, a third-party plugin can override a builtin by registering
    /// with the same provider id.
    private func wirePluginProviderInstances() {
        for (_, plugin) in pluginRegistry.providers {
            guard let providerPlugin = plugin as? any ProviderPlugin,
                  let provider = providerPlugin.makeProvider() else { continue }
            ProviderRegistry.registerDynamicProvider(
                provider,
                for: providerPlugin.descriptor.id
            )
        }
    }

    /// Wires the focus coordinator to consult `pluginRegistry` before
    /// falling back to `TerminalFocusRouteRegistry`. Phase 4 of the
    /// terminal-plugin migration: in v4.0-alpha all 8 builtins return
    /// the same handler instance the route registry would have, so this
    /// is a no-op behaviour-wise — but it lets a third-party plugin
    /// (when bundle loading lands in M2) override focus dispatch by
    /// declaring its bundle id and a `makeFocusStrategy()` factory.
    private func wirePluginFocusStrategyResolver() {
        let registry = pluginRegistry
        Task { [registry] in
            await TerminalFocusCoordinator.shared.setPluginStrategyResolver { [registry] bundleId in
                guard let bundleId else { return nil }
                return await MainActor.run {
                    for (_, plugin) in registry.terminals {
                        guard let terminal = plugin as? any TerminalPlugin else { continue }
                        if terminal.descriptor.bundleIdentifiers.contains(bundleId),
                           let strategy = terminal.makeFocusStrategy() {
                            return strategy
                        }
                    }
                    return nil
                }
            }
        }
    }

    /// Convenience: the primary usage VM (bound to the current
    /// provider). Many existing call sites still reference
    /// `appState.usageViewModel`; the registry is the source of truth.
    var usageViewModel: UsageViewModel { usageVMs.primary }

    private var cancellables: Set<AnyCancellable> = []

    init() {
        DefaultSettings.register()
        StatusLineSync.refreshManagedIntegrations()

        let selectedKind = ProviderRegistry.selectedProviderKind()
        providerKind = selectedKind
        let availableKinds = Set(ProviderRegistry.availableProviders())
        let startupKinds = ProviderRegistry.supportedProviders.filter { kind in
            availableKinds.contains(kind) || kind == selectedKind
        }

        let tracker = ActiveSessionsTracker()
        self.activeSessionsTracker = tracker
        let contexts = ProviderContextRegistry(activeSessionsTracker: tracker)
        self.providerContexts = contexts
        contexts.bootstrap(startupKinds)
        let lookupStore: (ProviderKind) -> SessionDataStore? = { [weak contexts] in contexts?.store(for: $0) }
        self.usageVMs = UsageVMRegistry(lookupStore: lookupStore)
        self.notchRuntime = NotchRuntimeCoordinator(
            notchCenter: notchCenter,
            activeSessionsTracker: tracker,
            lookupStore: lookupStore
        )

        let store = contexts.store(for: selectedKind)!
        self.store = store
        self.sessionViewModel = contexts.sessionViewModel(for: selectedKind)!
        usageVMs.primary.store = store
        configureUsageState(for: store.provider)

        // Sync subscription weekly reset date to SessionDataStore
        usageVMs.primary.$usageData
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
            usageVMs.bootSecondary(for: kind)
        }

        // Wire plugin-driven dispatch on top of the legacy registries.
        // Must run after all stored properties are initialized so the
        // closures can read `pluginRegistry`.
        wirePluginProviderInstances()
        wirePluginFocusStrategyResolver()

        // Wire hot-load: when the user clicks Allow on the prompt, the
        // plugin is dlopen'd into pluginRegistry immediately, then the
        // host re-derives every dynamic registry it owns so the new
        // plugin's bundle ids / aliases / provider instances become
        // live without a restart.
        let registry = pluginRegistry
        PluginTrustGate.setPluginRegistry(registry)
        PluginTrustGate.onPluginHotLoaded = { [weak self] manifest, _ in
            Self.refreshDynamicTerminalRegistries(from: registry)
            self?.wirePluginProviderInstances()
            DiagnosticLogger.shared.info(
                "Plugin hot-loaded: \(manifest.id) v\(manifest.version)"
            )
        }

        // Drain the trust queue collected during plugin discovery. Run
        // off the current call stack so the menu-bar / status panel
        // finishes its first layout before any modal NSAlert appears —
        // a modal during stored-property init blocks AppKit setup.
        DispatchQueue.main.async {
            PluginTrustGate.processPending()
        }
    }

    /// VM getter that maps a provider kind to its live UsageViewModel.
    /// Current provider → the primary `usageViewModel` singleton;
    /// others → the per-provider secondary VMs.
    func usageViewModel(for kind: ProviderKind) -> UsageViewModel? {
        usageVMs.viewModel(for: kind, currentProvider: providerKind)
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

        let context = providerContexts.ensureContext(for: kind)
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
        usageVMs.swap(from: oldKind, to: kind)

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
        providerContexts.stopAll()
        usageVMs.stopAllSecondaries()
    }

    func purgeNotchRuntime(for providers: [ProviderKind]) {
        notchRuntime.purge(for: providers)
    }

    func refreshNotchActiveSessionsIfEnabled() {
        notchRuntime.refreshIfEnabled()
    }

    func restoreNotchRuntime(for providers: [ProviderKind]) {
        notchRuntime.restore(for: providers)
    }

    func refreshProviderAfterAccountChange(_ kind: ProviderKind) {
        accounts.reload(for: kind)

        let rebuilt = providerContexts.rebuild(for: kind)
        let rebuiltStore = rebuilt.store
        let rebuiltViewModel = rebuilt.viewModel

        if providerKind == kind {
            store = rebuiltStore
            sessionViewModel = rebuiltViewModel
            usageViewModel.store = rebuiltStore
            configureUsageState(for: rebuiltStore.provider)

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
            usageVMs.bootSecondary(for: kind)
        }
    }

    func rebuildSessionCache(for kind: ProviderKind) {
        let context = providerContexts.ensureContext(for: kind)
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
        let stores = availableKinds.map { providerContexts.ensureContext(for: $0).store }
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
        // Wire the plugin-driven synthetic-prompt detector. Each
        // `ProviderPlugin` may override `isSyntheticPrompt(_:)` to flag
        // host-app background tasks (e.g. Codex.app ambient suggestions)
        // so they're dropped from the active session list. Adding a new
        // provider rule means overriding that one method on its plugin —
        // the tracker stays provider-agnostic.
        let registry = appState.pluginRegistry
        appState.activeSessionsTracker.syntheticPromptDetector = { [registry] provider, prompt in
            guard let plugin = registry.providerPlugin(id: provider.rawValue) else {
                return false
            }
            return plugin.isSyntheticPrompt(prompt)
        }

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
