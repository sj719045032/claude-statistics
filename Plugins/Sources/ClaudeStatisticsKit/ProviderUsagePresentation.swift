import Foundation

/// Whether a Provider plugin's usage UI is rendered as time windows
/// (Claude / Codex 5h+7d) or quota buckets (Gemini).
public enum ProviderUsageDisplayMode: Sendable {
    case windows
    case quotaBuckets
}

/// Per-window cell shown in the Usage tab when `displayMode == .windows`.
public struct ProviderUsageWindowPresentation: Sendable {
    public let titleLocalizationKey: String
    public let tabLabel: String
    public let durationValue: Int
    public let durationComponent: Calendar.Component
    public let granularity: TrendGranularity
    public let showsExhaustEstimate: Bool
    public let showsChart: Bool

    public init(
        titleLocalizationKey: String,
        tabLabel: String,
        durationValue: Int,
        durationComponent: Calendar.Component,
        granularity: TrendGranularity,
        showsExhaustEstimate: Bool,
        showsChart: Bool
    ) {
        self.titleLocalizationKey = titleLocalizationKey
        self.tabLabel = tabLabel
        self.durationValue = durationValue
        self.durationComponent = durationComponent
        self.granularity = granularity
        self.showsExhaustEstimate = showsExhaustEstimate
        self.showsChart = showsChart
    }
}

/// Per-trend chart shown alongside the Usage cells (e.g. Gemini's
/// per-model-family quota windows).
public struct ProviderUsageTrendPresentation: Identifiable, Hashable, Sendable {
    public enum Anchor: Hashable, Sendable {
        case now
        case quotaReset
    }

    public let id: String
    public let titleLocalizationKey: String
    public let tabLabel: String
    public let durationValue: Int
    public let durationComponent: Calendar.Component
    public let granularity: TrendGranularity
    public let anchor: Anchor
    public var modelFamily: String?
    /// When `anchor == .quotaReset` and the active provider has a
    /// `SubscriptionInfo` (e.g. GLM Coding Plan), look up `resetAt`
    /// from the matching `SubscriptionQuotaWindow.id` instead of from
    /// `UsageData.providerBuckets` (which is the Gemini path).
    public let subscriptionQuotaID: String?

    public init(
        id: String,
        titleLocalizationKey: String,
        tabLabel: String,
        durationValue: Int,
        durationComponent: Calendar.Component,
        granularity: TrendGranularity,
        anchor: Anchor,
        modelFamily: String? = nil,
        subscriptionQuotaID: String? = nil
    ) {
        self.id = id
        self.titleLocalizationKey = titleLocalizationKey
        self.tabLabel = tabLabel
        self.durationValue = durationValue
        self.durationComponent = durationComponent
        self.granularity = granularity
        self.anchor = anchor
        self.modelFamily = modelFamily
        self.subscriptionQuotaID = subscriptionQuotaID
    }
}

/// Top-level usage UI configuration a Provider plugin contributes.
/// Stage-3 ships two builtin instances (`.standard` for the
/// Claude/Codex window model, `.gemini` for the quota-bucket model);
/// stage 4 each plugin authors its own.
public struct ProviderUsagePresentation: Sendable {
    public enum PreferredWindow: Sendable {
        case short
        case long
    }

    public enum MenuBarMetric: Sendable {
        case preferredWindow
        case primaryQuotaBucket
    }

    public let displayMode: ProviderUsageDisplayMode
    public let shortWindow: ProviderUsageWindowPresentation?
    public let longWindow: ProviderUsageWindowPresentation?
    public let localTrendWindows: [ProviderUsageTrendPresentation]
    public let preferredWindow: PreferredWindow
    public let menuBarMetric: MenuBarMetric

    public init(
        displayMode: ProviderUsageDisplayMode,
        shortWindow: ProviderUsageWindowPresentation?,
        longWindow: ProviderUsageWindowPresentation?,
        localTrendWindows: [ProviderUsageTrendPresentation],
        preferredWindow: PreferredWindow,
        menuBarMetric: MenuBarMetric
    ) {
        self.displayMode = displayMode
        self.shortWindow = shortWindow
        self.longWindow = longWindow
        self.localTrendWindows = localTrendWindows
        self.preferredWindow = preferredWindow
        self.menuBarMetric = menuBarMetric
    }

    public static let standard = ProviderUsagePresentation(
        displayMode: .windows,
        shortWindow: ProviderUsageWindowPresentation(
            titleLocalizationKey: "usage.5hour",
            tabLabel: "5h",
            durationValue: -5,
            durationComponent: .hour,
            granularity: .fiveMinute,
            showsExhaustEstimate: true,
            showsChart: true
        ),
        longWindow: ProviderUsageWindowPresentation(
            titleLocalizationKey: "usage.7day",
            tabLabel: "7d",
            durationValue: -7,
            durationComponent: .day,
            granularity: .hour,
            showsExhaustEstimate: true,
            showsChart: true
        ),
        localTrendWindows: [],
        preferredWindow: .short,
        menuBarMetric: .preferredWindow
    )

    public static let gemini = ProviderUsagePresentation(
        displayMode: .quotaBuckets,
        shortWindow: nil,
        longWindow: nil,
        localTrendWindows: [
            ProviderUsageTrendPresentation(
                id: "current-pro",
                titleLocalizationKey: "usage.currentWindowTrend",
                tabLabel: "Pro",
                durationValue: -24,
                durationComponent: .hour,
                granularity: .fiveMinute,
                anchor: .quotaReset,
                modelFamily: "pro"
            ),
            ProviderUsageTrendPresentation(
                id: "current-flash",
                titleLocalizationKey: "usage.currentWindowTrend",
                tabLabel: "Flash",
                durationValue: -24,
                durationComponent: .hour,
                granularity: .fiveMinute,
                anchor: .quotaReset,
                modelFamily: "flash"
            ),
            ProviderUsageTrendPresentation(
                id: "current-flash-lite",
                titleLocalizationKey: "usage.currentWindowTrend",
                tabLabel: "Flash Lite",
                durationValue: -24,
                durationComponent: .hour,
                granularity: .fiveMinute,
                anchor: .quotaReset,
                modelFamily: "flash-lite"
            )
        ],
        preferredWindow: .long,
        menuBarMetric: .primaryQuotaBucket
    )
}
