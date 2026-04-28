import ClaudeStatisticsKit
import Foundation
import SwiftUI

/// Resolves plugin-contributed `ShareVisualTheme`s for plugin role ids,
/// so a `ShareRolePlugin` role can supply its own card palette via a
/// referenced `ShareCardThemePlugin` theme. Builtin role ids (the nine
/// roles in `ShareRoleEngine`) are not handled here — they keep using
/// `ShareRoleID.theme`. Lives in the host because color parsing needs
/// SwiftUI; SDK descriptors stay Foundation-only.
@MainActor
enum SharePluginThemes {
    /// Walk every registered `ShareRolePlugin`, look up each role's
    /// `themeID`, and resolve it against the registered
    /// `ShareCardThemePlugin`s. Roles without a `themeID`, or with an
    /// unknown one, are omitted — `ShareRoleEngine.buildRoleResult`
    /// then falls back to the neutral steadyBuilder palette.
    static func collect(plugins: PluginRegistry?) -> [String: ShareVisualTheme] {
        guard let plugins, !plugins.shareRoles.isEmpty else { return [:] }
        var themesByID: [String: ShareCardThemeDescriptor] = [:]
        for plugin in plugins.shareThemes.values {
            guard let themePlugin = plugin as? any ShareCardThemePlugin else { continue }
            for descriptor in themePlugin.themes {
                themesByID[descriptor.id] = descriptor
            }
        }
        guard !themesByID.isEmpty else { return [:] }

        var result: [String: ShareVisualTheme] = [:]
        for plugin in plugins.shareRoles.values {
            guard let rolePlugin = plugin as? any ShareRolePlugin else { continue }
            for role in rolePlugin.roles {
                guard let themeID = role.themeID,
                      let descriptor = themesByID[themeID] else { continue }
                result[role.id] = descriptor.toVisualTheme()
            }
        }
        return result
    }
}

extension ShareCardThemeDescriptor {
    /// Lift the SDK's hex/string fields into the host's SwiftUI-typed
    /// `ShareVisualTheme`. Malformed hex strings degrade to safe
    /// defaults so a plugin can't crash the share card.
    func toVisualTheme() -> ShareVisualTheme {
        ShareVisualTheme(
            backgroundTop: Color(shareThemeHex: backgroundTopHex) ?? .gray,
            backgroundBottom: Color(shareThemeHex: backgroundBottomHex) ?? .blue,
            accent: Color(shareThemeHex: accentHex) ?? .white,
            titleGradient: titleGradientHex.compactMap { Color(shareThemeHex: $0) },
            titleForeground: Color(shareThemeHex: titleForegroundHex) ?? .white,
            titleOutline: Color(shareThemeHex: titleOutlineHex) ?? .black.opacity(0.24),
            titleShadowOpacity: titleShadowOpacity,
            prefersLightQRCode: prefersLightQRCode,
            symbolName: symbolName,
            decorationSymbols: decorationSymbols,
            mascotPrimarySymbol: mascotPrimarySymbol,
            mascotSecondarySymbols: mascotSecondarySymbols
        )
    }
}

extension Color {
    /// Parse `#RRGGBB` or `#RRGGBBAA` into a SwiftUI `Color`. Returns
    /// nil on malformed input so callers can supply a safe default.
    init?(shareThemeHex hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var rgba: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgba) else { return nil }
        if s.count == 6 {
            let r = Double((rgba & 0xFF0000) >> 16) / 255.0
            let g = Double((rgba & 0x00FF00) >> 8) / 255.0
            let b = Double(rgba & 0x0000FF) / 255.0
            self.init(red: r, green: g, blue: b)
        } else {
            let r = Double((rgba & 0xFF000000) >> 24) / 255.0
            let g = Double((rgba & 0x00FF0000) >> 16) / 255.0
            let b = Double((rgba & 0x0000FF00) >> 8) / 255.0
            let a = Double(rgba & 0x000000FF) / 255.0
            self.init(red: r, green: g, blue: b, opacity: a)
        }
    }
}
