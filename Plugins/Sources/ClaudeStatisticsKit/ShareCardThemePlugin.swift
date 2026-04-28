import Foundation

/// Stable reference to a share-card visual theme contributed by a
/// plugin. Identity is `id` + `displayName`; the rest is the visual
/// payload the host renderer needs to draw the card. Colors travel as
/// `#RRGGBB` / `#RRGGBBAA` hex strings so this type stays
/// SwiftUI-free and Codable-clean across the SDK boundary; the host
/// converts them to `Color` at render time.
public struct ShareCardThemeDescriptor: Sendable, Hashable {
    /// Stable, globally-unique reverse-DNS identifier
    /// (e.g. `com.anthropic.theme.classic`).
    public let id: String
    public let displayName: String

    public let backgroundTopHex: String
    public let backgroundBottomHex: String
    public let accentHex: String
    public let titleGradientHex: [String]
    public let titleForegroundHex: String
    /// Outline color including alpha (`#RRGGBBAA`); host applies
    /// `.opacity` from the alpha channel.
    public let titleOutlineHex: String
    public let titleShadowOpacity: Double
    /// `true` requests a light QR code on dark backgrounds, mirroring
    /// the builtin `ShareVisualTheme.prefersLightQRCode`.
    public let prefersLightQRCode: Bool
    /// SF Symbol name shown in the title block.
    public let symbolName: String
    /// SF Symbol names sprinkled in the card background.
    public let decorationSymbols: [String]
    /// Primary mascot SF Symbol (overlaid in the persona scene).
    public let mascotPrimarySymbol: String
    /// Up to three secondary mascot symbols.
    public let mascotSecondarySymbols: [String]

    public init(
        id: String,
        displayName: String,
        backgroundTopHex: String,
        backgroundBottomHex: String,
        accentHex: String,
        titleGradientHex: [String],
        titleForegroundHex: String,
        titleOutlineHex: String,
        titleShadowOpacity: Double,
        prefersLightQRCode: Bool,
        symbolName: String,
        decorationSymbols: [String],
        mascotPrimarySymbol: String,
        mascotSecondarySymbols: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.backgroundTopHex = backgroundTopHex
        self.backgroundBottomHex = backgroundBottomHex
        self.accentHex = accentHex
        self.titleGradientHex = titleGradientHex
        self.titleForegroundHex = titleForegroundHex
        self.titleOutlineHex = titleOutlineHex
        self.titleShadowOpacity = titleShadowOpacity
        self.prefersLightQRCode = prefersLightQRCode
        self.symbolName = symbolName
        self.decorationSymbols = decorationSymbols
        self.mascotPrimarySymbol = mascotPrimarySymbol
        self.mascotSecondarySymbols = mascotSecondarySymbols
    }
}

/// A plugin that contributes one or more share-card visual templates.
/// Roles contributed by a `ShareRolePlugin` reference a theme via
/// `ShareRoleDescriptor.themeID`; if the referenced theme is missing
/// the host falls back to the neutral `steadyBuilder` palette.
public protocol ShareCardThemePlugin: Plugin {
    var themes: [ShareCardThemeDescriptor] { get }
}
