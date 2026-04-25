import Foundation

/// One-shot dispatch timer keyed by UUID. Used by `NotchNotificationCenter`
/// for both pending-response timeouts and auto-dismiss timers — same shape,
/// same lifecycle (fire once, then cancel). Encapsulates the
/// `DispatchSourceTimer` boilerplate so the center can ask "schedule this id
/// after N seconds" / "cancel this id" without juggling timer handles.
///
/// `@MainActor` because the center fires callbacks on the main queue and the
/// notch UI lives on main; sharing the actor avoids hop overhead and matches
/// the only call site.
@MainActor
final class NotificationTimerStore {
    private var timers: [UUID: DispatchSourceTimer] = [:]

    func contains(_ id: UUID) -> Bool {
        timers[id] != nil
    }

    /// Schedule a one-shot callback after `delay` seconds. No-op if a timer
    /// for `id` already exists — callers must `cancel` first if they need to
    /// reschedule. This matches the center's existing semantics where
    /// `scheduleAutoDismiss` skips re-scheduling for the same event.
    func schedule(id: UUID, after delay: TimeInterval, _ callback: @escaping @MainActor () -> Void) {
        guard timers[id] == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { Task { @MainActor in callback() } }
        timer.resume()
        timers[id] = timer
    }

    /// Cancel and remove the timer for `id`. Safe to call when no timer is
    /// registered — returns silently.
    func cancel(_ id: UUID) {
        guard let timer = timers.removeValue(forKey: id) else { return }
        timer.setEventHandler {}
        timer.cancel()
    }
}
