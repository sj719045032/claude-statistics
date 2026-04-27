import SwiftUI
import ClaudeStatisticsKit

struct ProviderBadge: View {
    let provider: ProviderKind
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(provider.descriptor.badgeColor)
                .frame(width: 8, height: 8)
            Text(provider.descriptor.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
