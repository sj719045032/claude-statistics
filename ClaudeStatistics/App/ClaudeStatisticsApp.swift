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
    /// Refreshes already-installed status-line integrations on
    /// startup. `plugins` filter so disabled provider plugins don't
    /// re-install their status lines on every launch — kill-switching
    /// gemini means its status-line install is also frozen.
    @MainActor
    static func refreshManagedIntegrations(plugins: PluginRegistry) {
        for kind in ProviderRegistry.availableProviders(plugins: plugins) {
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
    /// Snapshot of every provider kind that's both installed on disk
    /// and still represented by a registered `ProviderPlugin` in the
    /// live `pluginRegistry`. Disabling Gemini drops `.gemini` from
    /// here, which is what the menu-bar switcher and the developer
    /// rebuild list bind to so disabled providers vanish from the UI
    /// without restart.
    @Published private(set) var availableProviderKinds: [ProviderKind] = []
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
    /// Per-manifest-id factories for host (compiled-in) plugins. The
    /// init closure builds and registers fresh instances; the
    /// re-enable path in `PluginTrustGate.enable(...)` calls the
    /// matching factory so a previously-disabled host plugin comes
    /// back live without restart.
    static let hostPluginFactories = PluginRegistryBootstrap.hostPluginFactories

    let pluginRegistry: PluginRegistry = {
        let registry = PluginRegistry()
        // Chassis built-ins per `docs/PLUGIN_ARCHITECTURE.md` §1.1:
        // Claude provider + Apple Terminal are compiled into the host
        // and always considered before marketplace plugins.
        PluginRegistryBootstrap.registerHostPlugins(into: registry)
        // Discover .csplugin bundles. Bundled samples live in
        // Contents/PlugIns (shipped inside the .app, implicitly trusted);
        // user-installed plugins live under
        // ~/Library/Application Support/Claude Statistics/Plugins and
        // are gated by `PluginTrustGate`: previously-allowed plugins
        // load, previously-denied plugins are skipped, and unknown
        // plugins are queued for the post-launch NSAlert prompt.
        // Both paths consult the disabled-set so a kill-switched
        // plugin never reaches the trust prompt regardless of source.
        PluginRegistryBootstrap.loadBundledPlugins(into: registry)
        PluginRegistryBootstrap.loadUserPlugins(into: registry)
        // Emergency fallback: if every provider plugin is disabled
        // (or none ever loaded), force-restore Claude so the status
        // bar entry stays reachable. Without this, a user who has
        // killed all three builtins has no surface to flip one back
        // on — the popover, settings, even the menu-bar icon all
        // disappear once `availableProviderKinds` goes empty.
        let activeProviders = registry.providers.values.compactMap { $0 as? any ProviderPlugin }
        if activeProviders.isEmpty {
            let claudeId = ClaudePluginDogfood.manifest.id
            PluginTrustGate.disabledStore.setDisabled(false, for: claudeId)
            do {
                let claudePlugin = ClaudePluginDogfood()
                try registry.register(claudePlugin, source: .host)
                registry.removeDisabledRecord(id: claudeId)
                DiagnosticLogger.shared.warning(
                    "All providers were disabled — restored Claude as fallback so the menu bar entry stays reachable"
                )
            } catch {
                DiagnosticLogger.shared.warning(
                    "Failed to restore fallback Claude provider: \(error)"
                )
            }
        }
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
    ///
    /// Also pushes the set of disabled terminal `optionID`s so the
    /// picker, readiness, and auto-launch surfaces drop them. Builtin
    /// terminal plugin manifest ids equal their primary bundle id, so
    /// we resolve `manifest.id` → `TerminalCapability` via
    /// `capability(forBundleId:)` to recover the option id.
    static func refreshDynamicTerminalRegistries(from registry: PluginRegistry) {
        var pluginBundleIds: Set<String> = []
        var pluginNameAliases: [String: String] = [:]
        // Also build the set of plugin-backed capabilities for the
        // picker / readiness / launch surfaces. Each entry is an
        // adapter wrapping the live `TerminalPlugin` so editor
        // `.csplugin` bundles (VSCode / Cursor / Windsurf / Zed /
        // Trae) and chat-app plugins appear alongside the hardcoded
        // builtins in `Settings → Default Terminal`.
        var pluginCapabilities: [any TerminalCapability] = []
        for (manifestId, plugin) in registry.terminals {
            guard let terminal = plugin as? any TerminalPlugin else { continue }
            let descriptor = terminal.descriptor
            if let primaryBundleId = descriptor.bundleIdentifiers.sorted().first {
                pluginBundleIds.formUnion(descriptor.bundleIdentifiers)
                for alias in descriptor.terminalNameAliases {
                    pluginNameAliases[alias] = primaryBundleId
                }
            }
            pluginCapabilities.append(
                PluginBackedTerminalCapability(plugin: terminal, manifestId: manifestId)
            )
        }
        TerminalRegistry.registerDynamicBundleIdentifiers(pluginBundleIds)
        TerminalRegistry.registerDynamicTerminalNames(pluginNameAliases)
        TerminalRegistry.setPluginCapabilities(pluginCapabilities)

        // Compute the disabled option id set from disabled records.
        // Each disabled terminal manifest may correspond to either a
        // builtin host capability (manifest.id == primary bundle id
        // → resolve via TerminalRegistry.capability(forBundleId:))
        // OR a plugin-only capability that was hot-removed (already
        // out of pluginCapabilities, so we just record manifest.id
        // directly so any leftover preference referencing it is
        // treated as disabled too).
        var disabledOptionIDs: Set<String> = []
        for record in registry.disabledRecords() {
            guard record.manifest.kind == .terminal || record.manifest.kind == .both else { continue }
            if let cap = TerminalRegistry.capability(forBundleId: record.manifest.id),
               let optionID = cap.optionID {
                disabledOptionIDs.insert(optionID)
            } else {
                // Plugin-only terminal: optionID equals descriptor.id
                // which equals manifest.id (PluginBackedTerminalCapability
                // uses descriptor.id verbatim).
                disabledOptionIDs.insert(record.manifest.id)
            }
        }
        TerminalRegistry.setDisabledOptionIDs(disabledOptionIDs)
    }

    /// Caches every `ProviderPlugin.makeProvider()` result into
    /// `ProviderRegistry`'s dynamic store so `provider(for:)` prefers
    /// plugin-supplied instances over the legacy `switch`. Builtin
    /// dogfood wrappers return the existing `*.shared` singletons so
    /// this is behaviour-preserving today; once bundle loading lands in
    /// M2, a third-party plugin can override a builtin by registering
    /// with the same provider id.
    ///
    /// Clears the dynamic store first so a disabled plugin really
    /// disappears — without the clear, `provider(for: .gemini)` would
    /// keep returning the cached `GeminiProvider.shared` pointer even
    /// after `gemini` is gone from `pluginRegistry.providers`.
    ///
    /// Also registers UserDefaults defaults (menu-bar visibility) for
    /// each live `ProviderPlugin`'s descriptor id so a fresh install
    /// shows plugin providers in the strip without requiring the user
    /// to flip a switch. Idempotent — `registerDefault(forDescriptorID:)`
    /// is a no-op when the key has already been set.
    private func wirePluginProviderInstances() {
        Self.wirePluginProviderInstances(pluginRegistry: pluginRegistry)
    }

    /// Static variant safe to call before all `AppState` stored
    /// properties are initialized — `init` runs this *before*
    /// `contexts.bootstrap(...)` so the dynamic-providers store has
    /// the right plugin instances by the time
    /// `ProviderContextRegistry.bootstrap` calls
    /// `ProviderRegistry.provider(for: kind)` for each startup kind.
    /// The instance-method overload above is what hot-load /
    /// disable callbacks use after init has completed.
    private static func wirePluginProviderInstances(pluginRegistry: PluginRegistry) {
        ProviderRegistry.clearDynamicProviders()
        for (_, plugin) in pluginRegistry.providers {
            guard let providerPlugin = plugin as? any ProviderPlugin else { continue }
            let descriptorId = providerPlugin.descriptor.id
            MenuBarPreferences.registerDefault(forDescriptorID: descriptorId)
            if let provider = providerPlugin.makeProvider() {
                ProviderRegistry.registerDynamicProvider(provider, for: descriptorId)
            }
        }
        ProviderRegistry.refreshExtraPluginPricing(plugins: pluginRegistry)
    }

    private func recomputeAvailableProviderKinds() {
        availableProviderKinds = ProviderRegistry.availableProviders(plugins: pluginRegistry)
    }

    /// Reaction when a plugin is disabled. If the disabled plugin
    /// happens to be the current provider, the popover keeps showing
    /// stale data while the footer's switcher button is already gone
    /// — promote the next available kind so the UI stays consistent.
    /// Non-provider kinds (terminal, share-card) bail out early.
    private func handleProviderPluginDisabled(pluginID: String) {
        guard let record = pluginRegistry.disabled[pluginID],
              record.manifest.kind == .provider || record.manifest.kind == .both
        else { return }
        let nextAvailable = ProviderRegistry.availableProviders(plugins: pluginRegistry)
        guard !nextAvailable.contains(providerKind),
              let fallback = nextAvailable.first
        else { return }
        switchProvider(to: fallback)
    }

    /// Tear down the per-provider store + secondary usage VM whose
    /// plugin just got disabled. Without this the SessionDataStore's
    /// FSEvent watcher and the secondary UsageViewModel's auto-refresh
    /// keep running until the app restarts, wasting CPU and re-fetching
    /// usage data the user can no longer see. Skips the current
    /// provider — `handleProviderPluginDisabled` already promoted a
    /// fallback in that case, and tearing down the active store would
    /// leave UI bound to a dead reference.
    ///
    /// Also drops the disabled provider's `AccountManagers` reloader so
    /// `accounts.reload(for: kind)` from a future account-change path
    /// can't fire a closure capturing now-dead plugin state. Builtin
    /// Claude's reloader is seeded in `AccountManagers.init` and the
    /// Claude plugin can't be disabled (chassis built-in, refused by
    /// `PluginTrustGate.disable`), so this is effectively a no-op for
    /// builtins and meaningful only for plugin-registered reloaders.
    private func teardownProviderState(forDescriptorID descriptorID: String?) {
        guard let descriptorID,
              let kind = ProviderKind(rawValue: descriptorID),
              kind != providerKind
        else { return }
        providerContexts.remove(for: kind)
        usageVMs.remove(secondaryFor: kind)
        accounts.unregisterReloader(for: descriptorID)
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
    /// Subscription info flows from `ProfileViewModel` to the active
    /// `UsageViewModel` so the menu-bar percentage tracks the GLM /
    /// third-party quota when no Anthropic usage data is available.
    /// Re-built on every `configureProfileLoader` so it always points
    /// at the current provider's view model.
    private var subscriptionInfoSync: AnyCancellable?
    /// When `IdentityStore.activeIdentity` flips (user picked a
    /// different OAuth account / subscription token), reload the
    /// active provider's profile + usage so the displayed data
    /// matches the new identity.
    private var identityChangeSync: AnyCancellable?

    init() {
        DefaultSettings.register()
        // Wire the SDK terminal dispatcher before anything plugin-side
        // gets a chance to call it. Plugins (e.g. GeminiPlugin's
        // `openNewSession`) route launches through `TerminalDispatch`
        // because they can't import the host's `TerminalRegistry`.
        TerminalDispatch.setDispatcher { request in
            TerminalRegistry.launch(request)
        }
        // pluginRegistry is initialised before init body runs (stored
        // property closure), so plugin-disabled state is honoured by
        // every downstream filter on this path.
        StatusLineSync.refreshManagedIntegrations(plugins: pluginRegistry)
        // Pull every active provider plugin's subscription adapters
        // and endpoint detector into the router. Subscription
        // extension plugins (GLM Coding Plan / OpenRouter / Kimi /
        // …) contribute their adapters and account managers here
        // without any host-side changes — the host code only knows
        // the SDK protocols, not vendor specifics.
        SubscriptionAdapterRouter.shared.refresh(from: pluginRegistry)
        // First-run migration: users who pre-configured a third-party
        // subscription token through their provider's CLI had no
        // `IdentityStore` before this version, so its default
        // `.anthropicOAuth` would silently route them to OAuth. If
        // any installed subscription plugin's account manager
        // already reports an active account, flip to that
        // subscription so the new release matches their previous
        // experience.
        Self.migrateIdentityFromCLISettingsIfNeeded()

        let selectedKind = ProviderRegistry.selectedProviderKind()
        providerKind = selectedKind
        let availableKinds = Set(ProviderRegistry.availableProviders(plugins: pluginRegistry))
        var startupKinds = ProviderRegistry.allKnownDescriptors(plugins: pluginRegistry)
            .compactMap { ProviderKind(rawValue: $0.id) }
            .filter { availableKinds.contains($0) }
        // The selected kind always needs a context — even if its
        // plugin happens to be disabled or hasn't been loaded yet
        // (test target without bundles, etc.) — because line ~354
        // force-unwraps `contexts.store(for: selectedKind)`.
        if !startupKinds.contains(selectedKind) {
            startupKinds.append(selectedKind)
        }

        // Register plugin-supplied provider instances into
        // `ProviderRegistry`'s dynamic store. Must run before
        // `SessionDataStore.start()` (called from `bootstrap` →
        // `store.start()` → `provider.makeWatcher`) so the watcher
        // starts on the correct provider's filesystem layout. Now
        // that `SessionDataStore.provider` is a computed property
        // that resolves through `ProviderRegistry`, the value
        // automatically reflects later plugin enable/disable too —
        // we only need a one-time pre-bootstrap registration here.
        // Uses the static overload because not every `AppState`
        // stored property is initialized yet (phase-1 init).
        Self.wirePluginProviderInstances(pluginRegistry: pluginRegistry)

        let tracker = ActiveSessionsTracker()
        self.activeSessionsTracker = tracker
        let contexts = ProviderContextRegistry(activeSessionsTracker: tracker)
        self.providerContexts = contexts
        contexts.bootstrap(startupKinds)
        // `ensureContext` (not `store(for:)`) so a hot-loaded
        // provider's session store is materialized the first time
        // any consumer (e.g. `UsageVMRegistry.viewModel`) asks for
        // it. No more hand-coded `bootstrap` / `bootSecondary` calls
        // in `onPluginHotLoaded` — the strip's lazy lookup pulls
        // the chain.
        let lookupStore: (ProviderKind) -> SessionDataStore? = { [weak contexts] in
            contexts?.ensureContext(for: $0).store
        }
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

        // Plugin-driven terminal focus dispatch — instance method,
        // safe now that all stored properties are initialized.
        // (Provider dynamic registration already happened above,
        // before bootstrap.)
        wirePluginFocusStrategyResolver()

        // Boot one independent UsageViewModel per non-current startup provider
        // so the menu bar can display all enabled providers' usage in
        // parallel, using the same refresh cadence as the single-provider
        // path.
        for kind in startupKinds where kind != selectedKind {
            usageVMs.bootSecondary(for: kind)
        }
        recomputeAvailableProviderKinds()

        // Wire hot-load: when the user clicks Allow on the prompt, the
        // plugin is dlopen'd into pluginRegistry immediately, then the
        // host re-derives every dynamic registry it owns so the new
        // plugin's bundle ids / aliases / provider instances become
        // live without a restart.
        let registry = pluginRegistry
        ProviderRegistry.setSharedPluginRegistry(registry)
        PluginTrustGate.setPluginRegistry(registry)
        PluginTrustGate.setHostPluginFactories(AppState.hostPluginFactories)
        PluginTrustGate.onPluginHotLoaded = { [weak self] manifest, _ in
            Self.refreshDynamicTerminalRegistries(from: registry)
            // Hot-loaded plugin may have contributed a
            // SubscriptionAdapter / SubscriptionAccountManager (GLM,
            // future OpenRouter / Kimi); re-collect them so the
            // identity picker shows new sources without a restart.
            SubscriptionAdapterRouter.shared.refresh(from: registry)
            self?.wirePluginProviderInstances()
            self?.recomputeAvailableProviderKinds()
            // Reuse the per-provider notch toggle's state-changed
            // notification so AppDelegate's `applyNotchProviderPreferences`
            // re-runs: a freshly hot-loaded provider plugin needs its
            // hook installed (subject to the user's NotchPreferences
            // master switch) without waiting for a Settings toggle.
            // The notification name is general enough — "things that
            // affect notch state changed" — and avoids a parallel
            // observer purely for plugin lifecycle.
            NotificationCenter.default.post(
                name: NotchPreferences.stateChangedNotification,
                object: nil
            )
            DiagnosticLogger.shared.info(
                "Plugin hot-loaded: \(manifest.id) v\(manifest.version)"
            )
        }
        PluginTrustGate.onPluginDisabled = { [weak self] pluginID, providerDescriptorID in
            // Plugin's bundle stays in memory (macOS can't truly
            // unload a dlopen'd bundle); we just stop resolving it
            // from the registry. The dynamic-terminal-registry
            // refresher rebuilds its bundle-id / alias caches from
            // the registry's current contents, so the disabled
            // plugin's contributions disappear.
            Self.refreshDynamicTerminalRegistries(from: registry)
            // Same refresh on disable: rebuild the router so a
            // disabled subscription plugin's adapter / manager
            // disappears from the identity picker. The router's
            // self-heal also resets IdentityStore if the user's
            // active identity belonged to the now-gone plugin.
            SubscriptionAdapterRouter.shared.refresh(from: registry)
            ProviderRegistry.unregisterDynamicProvider(id: pluginID)
            self?.wirePluginProviderInstances()
            self?.handleProviderPluginDisabled(pluginID: pluginID)
            self?.recomputeAvailableProviderKinds()
            self?.teardownProviderState(forDescriptorID: providerDescriptorID)
            // Trigger AppDelegate's notch reconciliation so the
            // disabled plugin's notch runtime (cards, sessions,
            // dock badge) gets purged. Hooks in settings.json are
            // intentionally left alone — disable is reversible, only
            // PluginUninstaller drops them.
            NotificationCenter.default.post(
                name: NotchPreferences.stateChangedNotification,
                object: nil
            )
            DiagnosticLogger.shared.info("Plugin disabled: \(pluginID)")
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
        let pluginScores = SharePluginScoring.scores(
            plugins: pluginRegistry,
            context: mergedMetrics.evaluationContext(baseline: mergedBaseline)
        )
        let pluginThemes = SharePluginThemes.collect(plugins: pluginRegistry)
        return ShareRoleEngine.makeAllTimeRoleResult(
            metrics: mergedMetrics,
            baseline: mergedBaseline,
            pluginScores: pluginScores,
            pluginThemes: pluginThemes
        )
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

    private static let identityMigrationKey = "IdentityStore.didMigrate.v1"

    /// First-run migration: if any installed subscription plugin
    /// (GLM Coding Plan / OpenRouter / Kimi / …) already reports an
    /// active account — meaning the user pre-configured a token
    /// through their provider's CLI before this version landed — flip
    /// `IdentityStore` to that subscription so the new release shows
    /// quota immediately instead of silently falling back to OAuth.
    ///
    /// Stays vendor-agnostic: iterates every registered manager via
    /// the SDK protocol and picks the first one with state. Adding
    /// another subscription plugin tomorrow needs no host change.
    @MainActor
    private static func migrateIdentityFromCLISettingsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: identityMigrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: identityMigrationKey) }
        guard IdentityStore.shared.activeIdentity == .anthropicOAuth else { return }
        for manager in SubscriptionAdapterRouter.shared.allAccountManagers() {
            guard let activeID = manager.activeAccountID else { continue }
            IdentityStore.shared.activate(.subscription(
                adapterID: manager.adapterID,
                accountID: activeID
            ))
            DiagnosticLogger.shared.info(
                "IdentityStore: migrated to subscription(\(manager.adapterID), \(activeID)) from existing CLI config"
            )
            return
        }
    }

    private func configureProfileLoader(for provider: any SessionProvider) {
        let providerId = provider.providerId

        // Subscription loader fires only when the user has actually
        // overridden the base URL AND a non-default adapter claims
        // that host. Returning `nil` lets `ProfileViewModel` fall
        // through to the legacy OAuth profile loader, so the
        // Anthropic-on-official-endpoint case is byte-for-byte
        // unchanged. The detector is owned by whichever provider
        // plugin claimed `providerId` — `nil` means that plugin
        // doesn't support custom endpoints (Codex / Gemini today).
        let subscriptionLoader: () async -> SubscriptionInfo? = { @MainActor in
            // When `IdentityStore` has explicitly selected a
            // subscription account, route by adapter id — the user's
            // custom base URL might be outside the adapter's declared
            // `matchingHosts` (custom GLM proxy, future regional
            // mirror, …) and we shouldn't second-guess them.
            if case .subscription(let adapterID, _) = IdentityStore.shared.activeIdentity {
                guard let manager = SubscriptionAdapterRouter.shared
                    .accountManager(adapterID: adapterID),
                    let endpoint = manager.activeEndpoint,
                    let baseURL = endpoint.baseURL,
                    let adapter = SubscriptionAdapterRouter.shared
                        .adapter(forAdapterID: adapterID) else {
                    DiagnosticLogger.shared.info("subscriptionLoader[\(providerId)]: identity-based lookup found no live adapter for id=\(adapterID)")
                    return nil
                }
                do {
                    return try await adapter.fetchSubscription(
                        context: SubscriptionContext(
                            providerID: providerId,
                            baseURL: baseURL,
                            apiKey: endpoint.apiKey
                        )
                    )
                } catch {
                    DiagnosticLogger.shared.warning("subscriptionLoader[\(providerId)]: \(error.localizedDescription)")
                    return nil
                }
            }
            // No subscription identity selected — fall through to
            // the legacy host-matching path so an unset IdentityStore
            // (fresh install, OAuth-only user) still discovers GLM
            // via `~/.claude/settings.json`-derived endpoints.
            guard let detector = SubscriptionAdapterRouter.shared
                .detector(forProviderID: providerId) else { return nil }
            let endpoint = detector.detect()
            guard let baseURL = endpoint.baseURL,
                  let adapter = SubscriptionAdapterRouter.shared
                    .adapter(forProviderID: providerId, baseURL: baseURL),
                  !adapter.matchingHosts.contains("default") else {
                return nil
            }
            return try? await adapter.fetchSubscription(
                context: SubscriptionContext(
                    providerID: providerId,
                    baseURL: baseURL,
                    apiKey: endpoint.apiKey
                )
            )
        }

        profileViewModel.configure(
            profileLoader: { await provider.fetchProfile() },
            subscriptionLoader: subscriptionLoader
        )

        subscriptionInfoSync?.cancel()
        subscriptionInfoSync = profileViewModel.$subscriptionInfo
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.usageViewModel.subscriptionInfo = info
            }

        identityChangeSync?.cancel()
        identityChangeSync = IdentityStore.shared.$activeIdentity
            .removeDuplicates()
            .dropFirst()  // first emission is the persisted value at startup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.profileViewModel.forceRefresh()
                    await self.usageViewModel.forceRefresh()
                }
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
        // Build the active-session filter chain. Sources:
        //   1. Host-internal filters — e.g. `TerminalFocusableFilter`
        //      drops rows whose terminal can't be focused back.
        //   2. Each `TerminalPlugin.makeSessionFilters()` — terminal
        //      hosts contribute filters for *their own* synthetic
        //      sessions (Codex.app's ambient-suggestion task etc.).
        //      Removing the plugin removes its filter automatically.
        //   3. Each `ProviderPlugin.makeSessionFilters()` — reserved
        //      for CLI-intrinsic synthetic patterns (rare today).
        // Logical-AND: any `false` hides the row.
        var filters: [any SessionEventFilter] = [TerminalFocusableFilter()]
        for plugin in appState.pluginRegistry.terminals.values {
            guard let terminalPlugin = plugin as? any TerminalPlugin else { continue }
            filters.append(contentsOf: terminalPlugin.makeSessionFilters())
        }
        for plugin in appState.pluginRegistry.providers.values {
            guard let providerPlugin = plugin as? any ProviderPlugin else { continue }
            filters.append(contentsOf: providerPlugin.makeSessionFilters())
        }
        appState.activeSessionsTracker.sessionFilters = filters
        DiagnosticLogger.shared.info(
            "ActiveSession filters wired: [\(filters.map(\.id).joined(separator: ","))]"
        )

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

        WhatsNewPresenter.presentIfNeededOnLaunch()
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
        let plugins = appState.pluginRegistry
        Task { _ = try? await NotchHookSync.syncCurrent(plugins: plugins) }

        // Filter through `availableProviderKinds` so a plugin-disabled
        // provider's notch state isn't restored or purged twice — its
        // runtime was already torn down when the plugin was disabled.
        let availableKinds = appState.availableProviderKinds
        let enabledProviders = Set(availableKinds.filter {
            NotchPreferences.isEnabled($0)
        })
        let disabledProviders = ProviderRegistry.allKnownDescriptors(plugins: appState.pluginRegistry)
            .compactMap { ProviderKind(rawValue: $0.id) }
            .filter { !enabledProviders.contains($0) }
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
