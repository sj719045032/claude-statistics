import Foundation

/// A plugin that adds one or more third-party subscription endpoints
/// to an existing provider — without claiming a new `ProviderDescriptor`
/// or shipping a CLI integration.
///
/// Example: GLM Coding Plan piggy-backs on the Claude Code CLI by
/// setting `ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic`.
/// The user still uses `claude` (the CLI), but billing / quota /
/// account info come from GLM. A `SubscriptionExtensionPlugin` is
/// the right shape for this: it answers "GLM's quota API + token
/// management" without duplicating the Claude provider.
///
/// Extensions appear in the host's identity picker grouped under
/// `targetProviderID`'s section and contribute account managers the
/// same way `ProviderPlugin` does.
public protocol SubscriptionExtensionPlugin: Plugin {
    /// Provider id this extension hooks into (matches
    /// `ProviderDescriptor.id` of the Provider plugin whose CLI
    /// this extension augments). Determines where in the identity
    /// picker the extension's accounts appear.
    var targetProviderID: String { get }

    /// Adapters this extension contributes. Each adapter declares
    /// its `matchingHosts` so the router can pair it with the right
    /// active base URL.
    @MainActor
    func makeSubscriptionAdapters() -> [any SubscriptionAdapter]

    /// Per-model pricing rates the extension contributes to the
    /// host's pricing catalog. Keyed by raw model id as it appears
    /// in transcript JSONL (e.g. `"glm-4.6"`, `"glm-4.5-air"`).
    /// The host merges these into the extra-pricing pool consulted
    /// by `ModelPricing.builtinModels()` so cost rendering for
    /// JSONL rows tagged with these models lights up automatically
    /// — Tokens & Models card, trend chart `$` axis, Stats page,
    /// menu-bar tooltips. Default `[:]` opts out for extensions
    /// whose users don't need cost figures.
    var builtinPricingModels: [String: ModelPricingRates] { get }
}

extension SubscriptionExtensionPlugin {
    public var builtinPricingModels: [String: ModelPricingRates] { [:] }
}
