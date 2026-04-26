import Foundation

/// Optional plugin contribution that fetches up-to-date model pricing
/// from a remote source (e.g. the provider's pricing page). The host
/// merges fetched rates into its on-disk pricing catalog and surfaces
/// a "Refresh pricing" affordance in Settings → Pricing.
///
/// Plugins without a remote pricing endpoint can leave
/// `UsageProvider.pricingFetcher` nil — the host will fall back to the
/// `builtinPricingModels` seeds and the user's manual `pricing.json`.
public protocol ProviderPricingFetching: Sendable {
    /// Fetch latest rates keyed by model id. Throwing surfaces as a
    /// "Pricing refresh failed" toast in the UI; cancelling is idle.
    func fetchPricing() async throws -> [String: ModelPricingRates]
}
