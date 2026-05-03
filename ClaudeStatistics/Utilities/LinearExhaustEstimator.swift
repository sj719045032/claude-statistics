import Foundation

/// Linear extrapolation of "how long until this usage window hits
/// 100%". Shared by Claude's 5h/7d windows (`UsageViewModel`) and
/// the subscription-adapter quota rows (`SubscriptionQuotasView`)
/// so every window's "exhausts in …" badge is computed the same
/// way regardless of which provider supplied the data.
///
/// The two thresholds (`minUtilization`, `minElapsed`) gate noisy
/// early-window extrapolations: for short windows we wait until
/// at least 10% has been consumed before pretending the rate is
/// meaningful; for long windows we wait until at least one day
/// has elapsed.
enum LinearExhaustEstimator {
    static func estimate(
        utilization: Double,
        timeUntilReset: TimeInterval,
        windowDuration: TimeInterval,
        minUtilization: Double = 0,
        minElapsed: TimeInterval = 0
    ) -> (text: String, willExhaust: Bool)? {
        guard timeUntilReset > 0 else { return nil }
        let elapsed = windowDuration - timeUntilReset
        guard elapsed > 0, elapsed >= minElapsed else { return nil }

        let clamped = max(0, min(utilization, 100))
        guard clamped >= minUtilization else { return nil }
        let remaining = 100 - clamped
        guard remaining > 0 else { return nil }

        let rate = clamped / elapsed
        guard rate > 0 else { return nil }
        let secondsToExhaust = remaining / rate
        return (
            text: TimeFormatter.countdown(from: secondsToExhaust),
            willExhaust: secondsToExhaust < timeUntilReset
        )
    }
}
