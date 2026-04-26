import Foundation

/// Per-million-token pricing rates for one model, in USD.
///
/// This is the SDK-resident payload type that plugins emit through
/// `UsageProvider.builtinPricingModels` and `ProviderPricingFetching
/// .fetchPricing()`. The host `ModelPricing` service catalogs these and
/// uses them to estimate session cost.
///
/// The five-field shape captures Claude's prompt-caching pricing model
/// (separate 5-minute and 1-hour cache-write tiers, plus a cache-hit
/// rate). Providers without prompt caching can simply reuse `input` for
/// `cacheWrite5m` / `cacheWrite1h` and set `cacheRead` to zero — the
/// host's cost estimator falls back gracefully when cache fields are
/// not populated by the transcript.
public struct ModelPricingRates: Codable, Sendable, Equatable {
    public let input: Double
    public let output: Double
    /// 5-minute prompt-cache-write rate (typically 1.25× input).
    public let cacheWrite5m: Double
    /// 1-hour prompt-cache-write rate (typically 2× input).
    public let cacheWrite1h: Double
    /// Cache-hit rate (typically 0.1× input).
    public let cacheRead: Double

    public init(
        input: Double,
        output: Double,
        cacheWrite5m: Double,
        cacheWrite1h: Double,
        cacheRead: Double
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheWrite5m = "cache_write_5m"
        case cacheWrite1h = "cache_write_1h"
        case cacheRead = "cache_read"
    }
}
