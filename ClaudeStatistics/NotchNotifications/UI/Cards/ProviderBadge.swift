import SwiftUI
import ClaudeStatisticsKit

struct ProviderBadge: View {
    let provider: ProviderKind
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(provider.badgeColor)
                .frame(width: 8, height: 8)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

extension ProviderKind {
    /// Notch-island badge palette. Forwards to the descriptor's
    /// `badgeColor` field; the per-case literal palette used to live
    /// here as a `switch self`. Plugins can ship their own
    /// `descriptor.badgeColor` so this dispatcher no longer hard-codes
    /// the three builtin colours.
    var badgeColor: Color { descriptor.badgeColor }
}
