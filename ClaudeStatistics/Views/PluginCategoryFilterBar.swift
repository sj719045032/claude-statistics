import SwiftUI
import ClaudeStatisticsKit

/// Capsule-pill bar at the top of `PluginsSettingsView` (Installed tab)
/// and `PluginDiscoverView` for filtering the row list to one
/// category. Shows "All" plus one chip per category that actually has
/// rows; counts go in the chip label so the user can tell at a glance
/// where the plugins live.
///
/// Tapping the same chip twice clears the filter (toggles back to
/// "All"). Selection is stored as the rawValue string so callers can
/// share the chip bar between Installed and Discover even though
/// their underlying row types differ.
struct PluginCategoryFilterBar: View {
    /// Categories present in the current data set, in
    /// `PluginCatalogCategory.known` canonical order. Each entry pairs
    /// the category id with its row count (rendered after the title).
    let categories: [(id: String, count: Int)]
    /// `nil` ⇒ show every category (the "All" chip is selected).
    @Binding var selection: String?

    var body: some View {
        // Keep the bar terse when the data set is empty — no chips, no
        // "All" pill, just blank vertical space the surrounding view
        // takes care of via its own layout.
        if categories.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(
                        titleKey: "settings.plugins.category.all",
                        count: totalCount,
                        isSelected: selection == nil
                    ) {
                        selection = nil
                    }
                    ForEach(categories, id: \.id) { entry in
                        chip(
                            titleKey: localizationKey(for: entry.id),
                            count: entry.count,
                            isSelected: selection == entry.id
                        ) {
                            // Tapping the active chip clears back to All.
                            selection = (selection == entry.id) ? nil : entry.id
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var totalCount: Int { categories.reduce(0) { $0 + $1.count } }

    /// Use `LocalizedStringKey` (not pre-stringified `NSLocalizedString`)
    /// so SwiftUI re-resolves through `.environment(\.locale)` whenever
    /// the user switches app language at runtime.
    private func chip(
        titleKey: LocalizedStringKey,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(titleKey)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(isSelected ? 0 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Mirror of the same string keys both Installed and Discover use
    /// so the chip label matches the section header label exactly.
    private func localizationKey(for category: String) -> LocalizedStringKey {
        switch category {
        case PluginCatalogCategory.provider: return "settings.plugins.category.provider"
        case PluginCatalogCategory.terminal: return "settings.plugins.category.terminal"
        case PluginCatalogCategory.chatApp: return "settings.plugins.category.chat-app"
        case PluginCatalogCategory.shareCard: return "settings.plugins.category.share-card"
        case PluginCatalogCategory.editorIntegration: return "settings.plugins.category.editor-integration"
        case PluginCatalogCategory.subscription: return "settings.plugins.category.subscription"
        case PluginCatalogCategory.utility: return "settings.plugins.category.utility"
        default: return "settings.plugins.category.utility"
        }
    }
}
