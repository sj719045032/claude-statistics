import SwiftUI
import ClaudeStatisticsKit
import AppKit

struct ProjectGroupHeader: View {
    let group: ProjectGroup
    let isExpanded: Bool
    var isSelecting: Bool = false
    var selectionState: ProjectSelectionState = .none
    var isShiftSelecting: Bool = false
    var isRangePreviewed: Bool = false
    let onToggle: () -> Void
    var onToggleSelection: ((Bool) -> Void)? = nil
    var onSelectionHover: ((Bool) -> Void)? = nil
    let onNewSession: () -> Void
    let onAnalytics: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if isSelecting {
                Image(systemName: selectionIconName)
                    .font(.system(size: 14))
                    .foregroundStyle(selectionIconColor)
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleSelection?(isShiftSelecting || NSEvent.modifierFlags.contains(.shift))
                    }
                .help(selectionHelp)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text(group.shortPath)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if isHovered && !isSelecting {
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
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting && isShiftSelecting {
                onToggleSelection?(true)
            } else {
                onToggle()
            }
        }
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
            onSelectionHover?(hovering)
        }
    }

    private var backgroundColor: Color {
        if isRangePreviewed {
            return Color.blue.opacity(0.12)
        }
        if isShiftSelecting && isHovered && isSelecting {
            return Color.blue.opacity(0.08)
        }
        if isHovered {
            return Color.primary.opacity(0.04)
        }
        return .clear
    }

    private var selectionIconName: String {
        switch selectionState {
        case .none:
            return "circle"
        case .partial:
            return "minus.circle.fill"
        case .all:
            return "checkmark.circle.fill"
        }
    }

    private var selectionIconColor: Color {
        switch selectionState {
        case .none:
            return Color.gray.opacity(0.35)
        case .partial, .all:
            return .blue
        }
    }

    private var selectionHelp: LocalizedStringKey {
        switch selectionState {
        case .all:
            return "session.projectDeselect.help"
        case .none, .partial:
            return "session.projectSelect.help"
        }
    }
}
