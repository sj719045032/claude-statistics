import SwiftUI
import ClaudeStatisticsKit

/// Account-card content rendered in the Settings tab when a
/// `SubscriptionAdapter` returned a `SubscriptionInfo` for the active
/// provider — e.g. the user pointed Claude Code at GLM Coding Plan
/// instead of Anthropic OAuth.
///
/// Visually mirrors the existing OAuth profile block (display-name +
/// tier badge on the main row, secondary text underneath) so flipping
/// endpoints doesn't reshuffle the card. Per-window quota progress
/// belongs in the Usage tab, not here — the Account card is just
/// "who am I subscribed as?", not "how much have I used?"
struct SubscriptionAccountCard: View {
    let info: SubscriptionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(info.planName)
                    .font(.system(size: 13, weight: .medium))
                if info.note == nil, !info.quotas.isEmpty {
                    Text("subscription.card.active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            if let note = info.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if let dashboardURL = info.dashboardURL {
                Link(destination: dashboardURL) {
                    HStack(spacing: 3) {
                        Text("subscription.card.openDashboard")
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }
}
