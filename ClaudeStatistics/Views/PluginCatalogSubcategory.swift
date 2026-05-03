import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Finer-grained label shown on each row of the Plugins Discover /
/// Installed views. The marketplace `PluginCatalogCategory` collapses
/// terminals + editors + chat-apps into a single `terminal` bucket
/// ("Integrations"), which is the right granularity for filter pills
/// but obscures the difference between "iTerm2" and "VSCode" and
/// "Claude.app" inside one row.
///
/// The resolver below picks the most specific subcategory available
/// from whatever signals the row has — preferring the live plugin
/// instance (`TerminalPlugin.descriptor.category` /
/// `boundProviderID`), then the manifest's `category` string, then
/// the catalog entry's `category` string. Same data flows into both
/// views so a row labeled "App" in Discover is also labeled "App" in
/// Installed.
enum PluginCatalogSubcategory: String, CaseIterable {
    case provider
    case terminal
    case editor
    case app
    case subscription
    case shareCard
    case utility

    var displayKey: LocalizedStringKey {
        switch self {
        case .provider:     return "settings.plugins.subcategory.provider"
        case .terminal:     return "settings.plugins.subcategory.terminal"
        case .editor:       return "settings.plugins.subcategory.editor"
        case .app:          return "settings.plugins.subcategory.app"
        case .subscription: return "settings.plugins.subcategory.subscription"
        case .shareCard:    return "settings.plugins.subcategory.share-card"
        case .utility:      return "settings.plugins.subcategory.utility"
        }
    }

    var glyph: String {
        switch self {
        case .provider:     return "shippingbox"
        case .terminal:     return "apple.terminal"
        case .editor:       return "doc.text"
        case .app:          return "app.badge"
        case .subscription: return "creditcard"
        case .shareCard:    return "person.crop.square"
        case .utility:      return "wrench.and.screwdriver"
        }
    }

    /// Resolve the row's subcategory using the most precise signal
    /// available, preferring live plugin descriptors over manifest /
    /// catalog category strings:
    ///
    ///   1. `TerminalPlugin.descriptor.boundProviderID != nil`     → `.app`
    ///   2. `TerminalPlugin.descriptor.category == .editor`        → `.editor`
    ///   3. `TerminalPlugin.descriptor.category == .terminal`      → `.terminal`
    ///   4. plugin instance is `ProviderPlugin`                    → `.provider`
    ///   5. plugin instance is `SubscriptionExtensionPlugin`       → `.subscription`
    ///   6. plugin instance is `ShareRolePlugin`/`ShareCardThemePlugin` → `.shareCard`
    ///   7. catalog/manifest legacy disambiguators
    ///      ("chat-app", "editor-integration")                     → `.app` / `.editor`
    ///   8. canonicalised category bucket
    ///      (`provider`/`terminal`/`subscription`/`share-card`)    → matching coarse case
    ///   9. manifest.kind                                          → matching coarse case
    ///   10. fall through                                          → `.utility`
    static func resolve(
        plugin: (any Plugin)?,
        manifestKind: PluginKind?,
        manifestCategoryString: String?,
        catalogCategoryString: String?
    ) -> PluginCatalogSubcategory {
        if let terminal = plugin as? any TerminalPlugin {
            if terminal.descriptor.boundProviderID != nil {
                return .app
            }
            switch terminal.descriptor.category {
            case .editor:   return .editor
            case .terminal: return .terminal
            }
        }
        if plugin is any ProviderPlugin              { return .provider }
        if plugin is any SubscriptionExtensionPlugin { return .subscription }
        if plugin is any ShareRolePlugin             { return .shareCard }
        if plugin is any ShareCardThemePlugin        { return .shareCard }

        for raw in [manifestCategoryString, catalogCategoryString] {
            guard let raw, !raw.isEmpty else { continue }
            // Honour the legacy disambiguators before the canonical
            // collapse — `chat-app` / `editor-integration` lose
            // information when canonicalised to `terminal`.
            switch raw {
            case PluginCatalogCategory.chatApp:           return .app
            case PluginCatalogCategory.editorIntegration: return .editor
            default: break
            }
            switch PluginCatalogCategory.canonicalize(raw) {
            case PluginCatalogCategory.provider:     return .provider
            case PluginCatalogCategory.terminal:     return .terminal
            case PluginCatalogCategory.subscription: return .subscription
            case PluginCatalogCategory.shareCard:    return .shareCard
            default: break
            }
        }

        switch manifestKind {
        case .provider:              return .provider
        case .terminal, .both:       return .terminal
        case .shareRole, .shareCardTheme: return .shareCard
        case .subscriptionExtension: return .subscription
        case nil:                    return .utility
        }
    }
}
