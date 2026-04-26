import Foundation

/// Plugin contribution covering quota / window tracking + pricing for one
/// provider. Decoupled from `SessionDataProvider` so a plugin that only
/// emits transcript data can opt out of usage surfacing entirely.
///
/// Surfaces a few orthogonal capabilities:
/// - `usageSource` runs the live API calls populating quota windows
/// - `builtinPricingModels` seeds the pricing catalog at first launch
/// - `pricingFetcher` (optional) refreshes rates from the provider's docs
/// - `usagePresentation` describes how the menu-bar strip should render
public protocol UsageProvider: Sendable {
    var usagePresentation: ProviderUsagePresentation { get }
    var usageSource: (any ProviderUsageSource)? { get }

    /// Provider-owned built-in model pricing seeds.
    var builtinPricingModels: [String: ModelPricingRates] { get }

    /// Optional provider-specific remote pricing fetcher.
    var pricingFetcher: (any ProviderPricingFetching)? { get }

    /// Localization key describing the pricing source for this provider.
    var pricingSourceLocalizationKey: String? { get }

    /// Clickable source URL for this provider's pricing page.
    var pricingSourceURL: URL? { get }

    /// Localization key used after a successful remote pricing refresh.
    var pricingUpdatedLocalizationKey: String? { get }

    /// Short rotating segments shown in the multi-provider menu bar
    /// strip. Each segment is one "page" that rotates every few seconds
    /// alongside the provider's icon. The default implementation derives
    /// segments from `usagePresentation.menuBarMetric`; providers can
    /// override for custom behaviour.
    func menuBarStripSegments(from usage: UsageData?) -> [MenuBarStripSegment]
}

extension UsageProvider {
    public var usagePresentation: ProviderUsagePresentation { .standard }
    public var builtinPricingModels: [String: ModelPricingRates] { [:] }
    public var pricingFetcher: (any ProviderPricingFetching)? { nil }
    public var pricingSourceLocalizationKey: String? { nil }
    public var pricingSourceURL: URL? { nil }
    public var pricingUpdatedLocalizationKey: String? { nil }

    /// All segments reflect *used* percentage so colour thresholds and
    /// comparisons behave the same across providers. Gemini's buckets
    /// expose remaining percentage natively; we invert it here.
    public func menuBarStripSegments(from usage: UsageData?) -> [MenuBarStripSegment] {
        guard let usage else { return [] }
        switch usagePresentation.menuBarMetric {
        case .preferredWindow:
            var segments: [MenuBarStripSegment] = []
            if let short = usage.fiveHour, let tab = usagePresentation.shortWindow?.tabLabel {
                let used = short.utilization
                segments.append(.init(prefix: tab, value: "\(Int(used.rounded()))%", usedPercent: used))
            }
            if let long = usage.sevenDay, let tab = usagePresentation.longWindow?.tabLabel {
                let used = long.utilization
                segments.append(.init(prefix: tab, value: "\(Int(used.rounded()))%", usedPercent: used))
            }
            return segments
        case .primaryQuotaBucket:
            guard let buckets = usage.providerBuckets, !buckets.isEmpty else { return [] }
            return buckets.map { bucket in
                let abbr = MenuBarStripFormat.initials(of: bucket.title)
                let used = max(0, min(100, 100 - bucket.remainingPercentage))
                return MenuBarStripSegment(
                    prefix: abbr,
                    value: "\(Int(used.rounded()))%",
                    usedPercent: used
                )
            }
        }
    }
}
