import SwiftUI

struct TabOrderEditor: View {
    @Binding var tabOrder: [AppTab]
    var showsHeader: Bool = true
    @State private var selectedTab: AppTab?
    @State private var hoveredTab: AppTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Label("settings.tabOrder", systemImage: "rectangle.3.group")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            Text("settings.tabOrderHint")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 0) {
                ForEach(tabOrder) { tab in
                    let isSelected = selectedTab == tab

                    HStack(spacing: 4) {
                        if isSelected {
                            arrowButton(direction: -1, tab: tab)
                        }

                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14))
                            Text(tab.localizedName)
                                .font(.system(size: 9))
                        }

                        if isSelected {
                            arrowButton(direction: 1, tab: tab)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(isSelected ? Color.blue.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .contentShape(Rectangle())
                    .scaleEffect(hoveredTab == tab ? 1.15 : 1.0)
                    .animation(.spring(duration: 0.2, bounce: 0.3), value: hoveredTab)
                    .onHover { isHovered in
                        hoveredTab = isHovered ? tab : nil
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = selectedTab == tab ? nil : tab
                        }
                    }
                }
            }
        }
    }

    private func arrowButton(direction: Int, tab: AppTab) -> some View {
        let isDisabled = direction < 0 ? tabOrder.first == tab : tabOrder.last == tab
        let icon = direction < 0 ? "chevron.left" : "chevron.right"
        return Button(action: { move(tab, direction: direction) }) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverScale)
        .foregroundStyle(isDisabled ? Color.gray.opacity(0.3) : .white)
        .disabled(isDisabled)
    }

    private func move(_ tab: AppTab, direction: Int) {
        guard let index = tabOrder.firstIndex(of: tab) else { return }
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < tabOrder.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            tabOrder.swapAt(index, newIndex)
        }
        AppTab.saveOrder(tabOrder)
    }
}
