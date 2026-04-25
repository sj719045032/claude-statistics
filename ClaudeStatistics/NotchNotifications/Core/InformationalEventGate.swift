import Foundation

/// Rate-limits and deduplicates the notch's "informational" event surfacing
/// (`waitingInput` / `taskDone` / `taskFailed` / `sessionStart`). Without
/// this, an active CLI can flood the notch with the same waiting prompt or
/// retrigger a "task done" card every few seconds.
///
/// Two independent rules:
///
/// 1. **Waiting-input dedup**: once we've shown a waitingInput card for a
///    session, suppress further waitingInput from the same session until the
///    card is dismissed. The dismissal callback clears the marker.
/// 2. **Done/failed/start rate limit**: collapse repeated informational
///    events from the same session inside a short window (default 30s).
///
/// State is purely in-memory; resets across app restarts. The queue-touching
/// half (e.g. removing already-queued waitingInput entries during
/// `clearWaitingInput`) stays in the center — this gate just owns the keys.
struct InformationalEventGate {
    private var waitingShownByKey: Set<String> = []
    private var lastInformationalAtByKey: [String: Date] = [:]

    /// `provider:sessionId` key, or nil for events without a session id
    /// (those are never gated).
    static func key(for event: AttentionEvent) -> String? {
        guard !event.sessionId.isEmpty else { return nil }
        return "\(event.provider.rawValue):\(event.sessionId)"
    }

    func wasWaitingShown(key: String) -> Bool {
        waitingShownByKey.contains(key)
    }

    mutating func markWaitingShown(key: String) {
        waitingShownByKey.insert(key)
    }

    /// Drop the waiting marker for this key. Called when a waitingInput card
    /// is dismissed (so a later wait can resurface) or when the user takes
    /// an action that supersedes the waiting state (a tool fires, a new
    /// activity pulses, the session ends).
    mutating func clearWaitingShown(key: String) {
        waitingShownByKey.remove(key)
    }

    /// True if a recent informational event (taskDone/sessionStart/taskFailed)
    /// for this key was shown within the rate-limit window.
    func isWithinRateLimitWindow(key: String, now: Date = Date(), window: TimeInterval = 30) -> Bool {
        guard let last = lastInformationalAtByKey[key] else { return false }
        return now.timeIntervalSince(last) < window
    }

    mutating func recordInformational(key: String, at instant: Date = Date()) {
        lastInformationalAtByKey[key] = instant
    }
}
