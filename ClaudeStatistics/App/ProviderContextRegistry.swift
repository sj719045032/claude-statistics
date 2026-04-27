import ClaudeStatisticsKit
import Combine
import Foundation

/// Owns the per-provider `SessionDataStore` + `SessionViewModel` pair,
/// the runtime-bridge subscriptions used to feed Codex transcript
/// signals into the active-sessions tracker, and the lazy-create logic
/// for providers spun up after launch (e.g. when the user switches
/// from Claude to Gemini for the first time in a session).
///
/// Pulled out of `AppState` so the top-level state object isn't
/// responsible for store/VM lifecycle bookkeeping.
@MainActor
final class ProviderContextRegistry {
    private var stores: [ProviderKind: SessionDataStore] = [:]
    private var sessionViewModels: [ProviderKind: SessionViewModel] = [:]
    private var runtimeBridgeCancellables: [ProviderKind: AnyCancellable] = [:]
    private weak var activeSessionsTracker: ActiveSessionsTracker?

    init(activeSessionsTracker: ActiveSessionsTracker) {
        self.activeSessionsTracker = activeSessionsTracker
    }

    // MARK: Initial seeding

    /// Bulk-create + start contexts for the given providers. Used on
    /// launch to spin up every provider that has stored sessions, so
    /// menu-bar usage and notch state are warm without waiting for a
    /// user-driven switch.
    func bootstrap(_ kinds: [ProviderKind]) {
        for kind in kinds where stores[kind] == nil {
            let provider = ProviderRegistry.provider(for: kind)
            let store = SessionDataStore(provider: provider)
            let viewModel = SessionViewModel(store: store)
            stores[kind] = store
            sessionViewModels[kind] = viewModel
            store.start()
            bindRuntimeBridge(for: kind, store: store)
        }
    }

    // MARK: Lazy access

    /// Return existing context or create one on demand. Always succeeds;
    /// callers can rely on `.start()` having been invoked.
    @discardableResult
    func ensureContext(for kind: ProviderKind) -> (store: SessionDataStore, viewModel: SessionViewModel) {
        if let store = stores[kind], let viewModel = sessionViewModels[kind] {
            return (store, viewModel)
        }
        let provider = ProviderRegistry.provider(for: kind)
        let store = SessionDataStore(provider: provider)
        let viewModel = SessionViewModel(store: store)
        stores[kind] = store
        sessionViewModels[kind] = viewModel
        store.start()
        bindRuntimeBridge(for: kind, store: store)
        return (store, viewModel)
    }

    func store(for kind: ProviderKind) -> SessionDataStore? { stores[kind] }
    func sessionViewModel(for kind: ProviderKind) -> SessionViewModel? { sessionViewModels[kind] }
    func contains(_ kind: ProviderKind) -> Bool { stores[kind] != nil }

    // MARK: Lifecycle

    /// Tear down and rebuild a context. Used when a provider's
    /// credentials change so a stale store doesn't keep watching the
    /// previous account's session directory. Returns the freshly built
    /// (store, vm) pair so the caller can swap it in.
    @discardableResult
    func rebuild(for kind: ProviderKind) -> (store: SessionDataStore, viewModel: SessionViewModel) {
        if let existing = stores[kind] {
            existing.stop()
        }
        let provider = ProviderRegistry.provider(for: kind)
        let store = SessionDataStore(provider: provider)
        let viewModel = SessionViewModel(store: store)
        stores[kind] = store
        sessionViewModels[kind] = viewModel
        store.start()
        bindRuntimeBridge(for: kind, store: store)
        return (store, viewModel)
    }

    /// Stop watching/parsing across every booted provider. Called on
    /// app termination to flush DB writes and close FSEvent streams
    /// cleanly.
    func stopAll() {
        for store in stores.values {
            store.stop()
        }
    }

    // MARK: Runtime bridge (transcript → ActiveSessionsTracker)

    /// Providers that don't deliver in-flight activity through hooks
    /// (`descriptor.syncsTranscriptToActiveSessions == true`, e.g. Codex)
    /// need transcript signals (sessions/quickStats/parsedStats) piped
    /// into the active-sessions tracker so the notch's idle-peek row
    /// reflects current tool activity. Other providers get this info
    /// through hooks directly, so there's no bridge for them.
    private func bindRuntimeBridge(for kind: ProviderKind, store: SessionDataStore) {
        runtimeBridgeCancellables[kind]?.cancel()

        guard kind.descriptor.syncsTranscriptToActiveSessions else {
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
            guard let tracker = self?.activeSessionsTracker,
                  NotchPreferences.isEnabled(kind) else { return }
            tracker.syncTranscriptSignals(
                provider: kind,
                sessions: sessions,
                quickStats: quickStats,
                parsedStats: parsedStats
            )
        }
    }
}
