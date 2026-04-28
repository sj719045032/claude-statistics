import Foundation

/// Stable reference to a share-card role contributed by a plugin.
/// Stage 3 introduces only the identity-side fields so the plugin
/// loader can deduplicate roles across plugins; stage 4 extends with
/// `proofMetricKeys`, `category`, and the badge resource.
public struct ShareRoleDescriptor: Sendable, Hashable {
    /// Stable, globally-unique reverse-DNS identifier
    /// (e.g. `com.anthropic.role.night-shift`).
    public let id: String
    public let displayName: String
    /// Optional reference to a `ShareCardThemeDescriptor.id` contributed
    /// by some `ShareCardThemePlugin`. Nil means "use the host's neutral
    /// fallback theme (steadyBuilder)". Unknown ids fall back the same
    /// way — the host never crashes on a stale theme reference.
    public let themeID: String?

    public init(id: String, displayName: String, themeID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.themeID = themeID
    }
}

/// A plugin that contributes one or more share-card roles plus the
/// scoring functions that decide which role wins for a given user's
/// metrics. The minimal protocol surface is `roles` (which descriptors
/// the plugin contributes) and `evaluate(context:)` (how each role
/// scores against an aggregate context). The default `evaluate`
/// returns an empty array, so a plugin that only wants to declare
/// roles for some other UI surface (without participating in the
/// builtin ranking) can omit the method.
public protocol ShareRolePlugin: Plugin {
    var roles: [ShareRoleDescriptor] { get }

    /// Score each `roles` descriptor for the supplied evaluation
    /// context. Returned `roleID`s should match descriptor ids the
    /// plugin previously declared; unknown ids are dropped by the host
    /// before merging. Scores are clamped to `[0, 1]`.
    func evaluate(context: ShareRoleEvaluationContext) -> [ShareRoleScoreEntry]
}

public extension ShareRolePlugin {
    func evaluate(context: ShareRoleEvaluationContext) -> [ShareRoleScoreEntry] { [] }
}
