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

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A plugin that contributes one or more share-card roles plus the
/// scoring functions that decide which role wins for a given user's
/// metrics. Stage 3 introduces the minimal protocol surface — just
/// `roles` — so the host's `PluginRegistry` and any third-party
/// plugin can interoperate at the metadata level. Stage 4 adds
/// `evaluate(metrics:baseline:) -> [ShareRoleScore]` once
/// `ShareMetrics` migrates into this SDK.
public protocol ShareRolePlugin: Plugin {
    var roles: [ShareRoleDescriptor] { get }
}
