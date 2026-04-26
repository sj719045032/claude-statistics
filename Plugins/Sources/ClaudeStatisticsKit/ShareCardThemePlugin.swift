import Foundation

/// Stable reference to a share-card visual theme contributed by a
/// plugin. Stage 3 introduces only the identity-side fields so the
/// loader can list themes in the share dialog; stage 4 extends with
/// preview asset, supported categories, and the SwiftUI factory.
public struct ShareCardThemeDescriptor: Sendable, Hashable {
    /// Stable, globally-unique reverse-DNS identifier
    /// (e.g. `com.anthropic.theme.classic`).
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A plugin that contributes one or more share-card visual templates.
/// Stage 3 introduces the minimal protocol surface — just `themes` —
/// so the host's share dialog can list options. Stage 4 adds
/// `makeCardView(input:)` once `ShareCardInput` migrates into this
/// SDK.
public protocol ShareCardThemePlugin: Plugin {
    var themes: [ShareCardThemeDescriptor] { get }
}
