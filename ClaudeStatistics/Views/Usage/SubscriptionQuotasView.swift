import SwiftUI
import ClaudeStatisticsKit

/// Usage-tab content when the active provider's subscription comes
/// from a `SubscriptionAdapter` (e.g. GLM Coding Plan) instead of the
/// vendor's OAuth API. Renders each quota window through the same
/// `UsageWindowRow` Claude's 5h/7d uses so the visual rhythm
/// (typography, bar height, countdown placement) is identical
/// regardless of which adapter populated `info`.
struct SubscriptionQuotasView: View {
    let info: SubscriptionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = info.note {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if info.quotas.isEmpty, info.note == nil {
                emptyState
            } else {
                ForEach(info.quotas) { window in
                    UsageWindowRow(
                        title: LocalizedStringKey(window.title),
                        utilization: max(0, min(window.percentage, 100)),
                        countdown: countdown(for: window),
                        exhaustEstimate: exhaustEstimate(for: window)
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("subscription.quotas.noData")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func countdown(for window: SubscriptionQuotaWindow) -> String? {
        guard let resetAt = window.resetAt else { return nil }
        let interval = resetAt.timeIntervalSinceNow
        guard interval > 0 else { return nil }
        return TimeFormatter.countdown(from: interval)
    }

    /// Linear "exhausts in …" estimate, gated by the same thresholds
    /// Claude uses: short windows (< 24h) need ≥ 10% utilization,
    /// long windows need ≥ 1 day of elapsed history. Adapters that
    /// don't supply `windowDuration` opt out automatically.
    private func exhaustEstimate(for window: SubscriptionQuotaWindow) -> (text: String, willExhaust: Bool)? {
        guard let resetAt = window.resetAt,
              let duration = window.windowDuration else { return nil }
        let timeUntilReset = resetAt.timeIntervalSinceNow
        let isShort = duration < 86400
        return LinearExhaustEstimator.estimate(
            utilization: window.percentage,
            timeUntilReset: timeUntilReset,
            windowDuration: duration,
            minUtilization: isShort ? 10 : 0,
            minElapsed: isShort ? 0 : 86400
        )
    }
}
