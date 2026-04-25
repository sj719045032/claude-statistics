import SwiftUI

struct TabButton: View {
    let title: LocalizedStringKey
    let icon: String
    let isSelected: Bool
    var showBadge: Bool = false
    var fontScale: Double = 1.0
    let action: () -> Void
    let namespace: Namespace.ID
    @State private var isHovered = false
    @State private var bounceCount = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 14 * fontScale))
                        .symbolEffect(.bounce, value: bounceCount)
                        .onChange(of: isSelected) { _, newValue in
                            if newValue { bounceCount += 1 }
                        }
                    if showBadge {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
                Text(title)
                    .font(.system(size: 10 * fontScale, weight: isSelected ? .medium : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? .primary : isHovered ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 24, height: 2.5)
                    .matchedGeometryEffect(id: "tab_indicator", in: namespace)
            }
        }
    }
}
