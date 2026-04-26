import SwiftUI
import ClaudeStatisticsKit

struct ProjectGroupHeader: View {
    let group: ProjectGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onAnalytics: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text(group.shortPath)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if isHovered {
                Button(action: onAnalytics) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("View project analytics")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))

                Button(action: onNewSession) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.hoverScale)
                .help("session.new.help")
            }

            Text("\(group.sessions.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            if group.totalCost > 0 {
                Text(formatCost(group.totalCost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(costColor(group.totalCost))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
    }
}
