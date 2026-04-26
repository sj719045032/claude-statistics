import Foundation

/// Helpers a Provider plugin uses when contributing rotating menu-bar
/// strip cells.
public enum MenuBarStripFormat {
    /// "Flash Lite" → "FL", "Pro" → "P", "GPT 5" → "G5". Takes the
    /// first alphanumeric character of each space-separated token.
    /// Uppercased so short labels read cleanly in the menu bar.
    public static func initials(of title: String) -> String {
        let tokens = title.split { !$0.isLetter && !$0.isNumber }
        let letters = tokens.compactMap { $0.first.map(Character.init) }
        let joined = String(letters).uppercased()
        return joined.isEmpty ? title : joined
    }
}

/// One page in the rotating multi-provider menu bar strip. Split into
/// `prefix` (window or bucket label, e.g. "5h", "FL") and `value`
/// (e.g. "72%") so the cell can stack them across two lines.
/// `usedPercent` is always *consumed* fraction (0–100), never
/// "remaining", so colour thresholds behave the same across providers.
public struct MenuBarStripSegment: Equatable, Sendable {
    public let prefix: String
    public let value: String
    public let usedPercent: Double

    public init(prefix: String, value: String, usedPercent: Double) {
        self.prefix = prefix
        self.value = value
        self.usedPercent = usedPercent
    }
}
