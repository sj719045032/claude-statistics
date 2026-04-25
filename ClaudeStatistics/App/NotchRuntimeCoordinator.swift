import Foundation

/// Bridges the notch UI state (NotchNotificationCenter +
/// ActiveSessionsTracker) with per-provider session data, providing the
/// purge / refresh / restore lifecycle actions invoked when the user
/// toggles a provider's notch switch or reloads after an account
/// change.
///
/// Pulled out of `AppState` so the top-level state object isn't
/// responsible for the notch-specific bookkeeping. Holds weak
/// references to its collaborators — it's never the source of truth
/// for them.
@MainActor
final class NotchRuntimeCoordinator {
    private weak var notchCenter: NotchNotificationCenter?
    private weak var activeSessionsTracker: ActiveSessionsTracker?
    private let lookupStore: (ProviderKind) -> SessionDataStore?

    init(
        notchCenter: NotchNotificationCenter,
        activeSessionsTracker: ActiveSessionsTracker,
        lookupStore: @escaping (ProviderKind) -> SessionDataStore?
    ) {
        self.notchCenter = notchCenter
        self.activeSessionsTracker = activeSessionsTracker
        self.lookupStore = lookupStore
    }

    /// Drop everything the notch knows about the given providers — used
    /// when the user disables a provider's notch switch.
    func purge(for providers: [ProviderKind]) {
        for kind in providers {
            notchCenter?.purgeProvider(kind)
            activeSessionsTracker?.purgeRuntime(for: kind)
        }
    }

    /// Lightweight refresh of the active-session tracker (rescan PIDs,
    /// recompute liveness). No-op when no provider has notch enabled.
    func refreshIfEnabled() {
        guard NotchPreferences.anyProviderEnabled else { return }
        activeSessionsTracker?.refresh()
    }

    /// Re-seed the active-session tracker with session/transcript data
    /// after a provider's notch toggle goes from off → on. Without
    /// feeding stats here, the triptych UI shows shell-only "No prompt
    /// yet / Idle / Waiting for input" until the first
    /// syncTranscriptSignals debounce fires.
    func restore(for providers: [ProviderKind]) {
        guard let tracker = activeSessionsTracker else { return }
        for kind in providers {
            let store = lookupStore(kind)
            let restoredSource: [Session]
            if let sessions = store?.sessions, !sessions.isEmpty {
                restoredSource = sessions
            } else {
                restoredSource = ProviderRegistry.provider(for: kind).scanSessions()
            }
            tracker.restoreRuntime(
                for: kind,
                sessions: restoredSource,
                quickStats: store?.quickStats ?? [:],
                parsedStats: store?.parsedStats ?? [:]
            )
        }
    }
}
