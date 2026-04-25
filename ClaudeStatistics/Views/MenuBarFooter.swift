import SwiftUI

/// Compact "Parsing N/M" pill shown in the panel footer while a parse
/// is in flight. Replaces the full text with a progress bar + short
/// label so the footer stays one line tall.
struct ParseProgressBadge: View {
    let progress: String
    let percent: Double?
    let fontScale: Double

    private var compactText: String {
        progress
            .replacingOccurrences(of: "Parsing ", with: "")
            .replacingOccurrences(of: "Loading...", with: "Loading")
    }

    var body: some View {
        HStack(spacing: 6) {
            if let percent {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: max(6, 38 * min(max(percent, 0), 1)))
                }
                .frame(width: 38, height: 4)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.45)
                    .frame(width: 8, height: 8)
            }

            Text(compactText)
                .font(.system(size: 10 * fontScale, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 8)
        .accessibilityLabel(progress)
    }
}

/// One pill in the footer's provider switcher. The container draws the
/// segmented background; this view just renders one segment + handles
/// tap. `isCurrent` decides accent fill; `isInstalled` greys it out.
struct ProviderSwitcherButton: View {
    let kind: ProviderKind
    let isCurrent: Bool
    let isInstalled: Bool
    let fontScale: Double
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(kind.displayName)
                .font(.system(size: 10 * fontScale, weight: isCurrent ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(isCurrent ? Color.accentColor : Color.clear)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(isInstalled ? Color.secondary : Color.secondary.opacity(0.4)))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!isInstalled)
        .help(isInstalled ? kind.displayName : "\(kind.displayName) not installed")
    }
}
