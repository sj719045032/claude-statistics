import Combine
import Foundation

/// Owns the usage view models needed by the menu-bar strip. The
/// "primary" VM is bound to whichever provider the user has currently
/// selected; "secondary" VMs keep the strip's other rows fresh in the
/// background so they don't flash stale data when the user rotates
/// providers.
///
/// Pulled out of `AppState` so the top-level state object isn't
/// responsible for the promote/demote bookkeeping that swaps VMs in
/// and out of the secondary pool on provider switch.
@MainActor
final class UsageVMRegistry {
    let primary = UsageViewModel()

    /// Per-provider VMs for providers that are *not* currently selected.
    /// Published so SwiftUI views (notably the multi-provider strip) re-
    /// render when a provider is promoted/demoted.
    @Published private(set) var secondaries: [ProviderKind: UsageViewModel] = [:]

    private let lookupStore: (ProviderKind) -> SessionDataStore?
    private var cancellables: Set<AnyCancellable> = []

    init(lookupStore: @escaping (ProviderKind) -> SessionDataStore?) {
        self.lookupStore = lookupStore
    }

    /// Resolve the live VM for a kind. Current provider → primary;
    /// other providers → secondary pool, lazily created on first
    /// access. Lazy creation is the root of the post-plugin-hot-load
    /// fix: the menu-bar strip (and anything else that calls this)
    /// triggers a fresh secondary VM the moment a new provider
    /// becomes visible, instead of relying on a hand-coded
    /// `bootSecondary` from every wire-up callback.
    /// Returns nil only when there is no `SessionDataStore` for the
    /// kind yet — `lookupStore` is the gate.
    func viewModel(for kind: ProviderKind, currentProvider: ProviderKind) -> UsageViewModel? {
        if kind == currentProvider { return primary }
        if let existing = secondaries[kind] { return existing }
        guard lookupStore(kind) != nil else { return nil }
        let vm = makeSecondary(for: kind)
        secondaries[kind] = vm
        return vm
    }

    // MARK: Lifecycle

    /// Boot a fresh secondary VM for `kind`, configure it for the
    /// provider's usage source, kick off cache load + auto-refresh if
    /// supported, and bind its weekly-reset signal back to the matching
    /// store. Idempotent — call again to rebuild after credential
    /// changes.
    func bootSecondary(for kind: ProviderKind) {
        if let old = secondaries.removeValue(forKey: kind) {
            old.stopAutoRefresh()
        }
        secondaries[kind] = makeSecondary(for: kind)
    }

    /// On provider switch, the incoming kind moves from secondary →
    /// primary (so we stop its background refresh; the primary VM takes
    /// over). The outgoing kind goes the other way: it gets a fresh
    /// secondary VM if its store is still around.
    func swap(from oldKind: ProviderKind, to newKind: ProviderKind) {
        if let promoted = secondaries.removeValue(forKey: newKind) {
            promoted.stopAutoRefresh()
        }
        if lookupStore(oldKind) != nil {
            secondaries[oldKind] = makeSecondary(for: oldKind)
        }
    }

    /// Stop every secondary VM's auto-refresh (primary stays alive — its
    /// lifecycle is owned elsewhere). Called on app termination.
    func stopAllSecondaries() {
        for vm in secondaries.values {
            vm.stopAutoRefresh()
        }
    }

    /// Tear down a single provider's secondary VM. Stops its auto-
    /// refresh timer and drops it from the pool — once dereferenced
    /// the VM's `cacheWatcher` deinit fires and FS sources are torn
    /// down. Called when a provider plugin is disabled. No-op for the
    /// current provider (its VM is the primary, which keeps living).
    func remove(secondaryFor kind: ProviderKind) {
        if let vm = secondaries.removeValue(forKey: kind) {
            vm.stopAutoRefresh()
        }
    }

    // MARK: Factory

    private func makeSecondary(for kind: ProviderKind) -> UsageViewModel {
        let vm = UsageViewModel()
        guard let store = lookupStore(kind) else { return vm }
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
                self?.lookupStore(kind)?.weeklyResetDate = resetDate
            }
            .store(in: &cancellables)
        return vm
    }
}
