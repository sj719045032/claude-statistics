import Foundation

protocol SessionWatcher: AnyObject {
    func start()
    func stop()
}

enum ProviderUsageDisplayMode {
    case windows
    case quotaBuckets
}

struct ProviderUsageWindowPresentation {
    let titleLocalizationKey: String
    let tabLabel: String
    let durationValue: Int
    let durationComponent: Calendar.Component
    let granularity: TrendGranularity
    let showsExhaustEstimate: Bool
    let showsChart: Bool
}

struct ProviderUsageTrendPresentation: Identifiable, Hashable {
    enum Anchor: Hashable {
        case now
        case quotaReset
    }

    let id: String
    let titleLocalizationKey: String
    let tabLabel: String
    let durationValue: Int
    let durationComponent: Calendar.Component
    let granularity: TrendGranularity
    let anchor: Anchor
    var modelFamily: String? = nil
}

struct ProviderUsagePresentation {
    enum PreferredWindow {
        case short
        case long
    }

    enum MenuBarMetric {
        case preferredWindow
        case primaryQuotaBucket
    }

    let displayMode: ProviderUsageDisplayMode
    let shortWindow: ProviderUsageWindowPresentation?
    let longWindow: ProviderUsageWindowPresentation?
    let localTrendWindows: [ProviderUsageTrendPresentation]
    let preferredWindow: PreferredWindow
    let menuBarMetric: MenuBarMetric

    static let standard = ProviderUsagePresentation(
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

    static let gemini = ProviderUsagePresentation(
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

struct ProviderUsageSnapshot {
    let data: UsageData
    let fetchedAt: Date
}

struct SearchIndexMessage {
    let role: String
    let content: String
    let timestamp: Date?
}

protocol ProviderUsageSource {
    var dashboardURL: URL? { get }
    var usageCacheFilePath: String? { get }

    func loadCachedSnapshot() -> ProviderUsageSnapshot?
    func refreshSnapshot() async throws -> ProviderUsageSnapshot
    func refreshCredentials() async -> Bool
}

extension ProviderUsageSource {
    var dashboardURL: URL? { nil }
    var usageCacheFilePath: String? { nil }
    var historyStore: UsageHistoryStore? { nil }

    func refreshCredentials() async -> Bool {
        false
    }
}

protocol ProviderPricingFetching {
    func fetchPricing() async throws -> [String: ModelPricing.Pricing]
}

struct StatusLineLegendItem: Identifiable {
    let example: String
    let descriptionLocalizationKey: String

    var id: String { "\(example)::\(descriptionLocalizationKey)" }
}

struct StatusLineLegendSection: Identifiable {
    let titleLocalizationKey: String
    let items: [StatusLineLegendItem]

    var id: String { titleLocalizationKey }
}

/// Encapsulates statusline install/restore operations for a specific provider.
/// Title and description localization keys are plain strings to avoid SwiftUI import.
protocol StatusLineInstalling {
    var isInstalled: Bool { get }
    /// Whether a restore/rollback option is available
    var hasRestoreOption: Bool { get }
    var titleLocalizationKey: String { get }
    var descriptionLocalizationKey: String { get }
    var legendSections: [StatusLineLegendSection] { get }
    func install() throws
    func restore() throws
}

extension StatusLineInstalling {
    var hasRestoreOption: Bool { false }
    var legendSections: [StatusLineLegendSection] { [] }
    func restore() throws {}
}

protocol SessionProvider: Sendable {
    var kind: ProviderKind { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    var usagePresentation: ProviderUsagePresentation { get }
    var usageSource: (any ProviderUsageSource)? { get }

    /// The provider's config directory path (e.g. `~/.claude`). Used to detect installation.
    var configDirectory: String { get }

    /// Whether stored credentials exist. `nil` means the check is not applicable for this provider.
    var credentialStatus: Bool? { get }
    /// Returns the statusline installer for this provider, or `nil` if not supported.
    var statusLineInstaller: (any StatusLineInstalling)? { get }
    /// Provider-owned built-in model pricing seeds.
    var builtinPricingModels: [String: ModelPricing.Pricing] { get }
    /// Optional provider-specific remote pricing fetcher.
    var pricingFetcher: (any ProviderPricingFetching)? { get }
    /// Localization key describing the pricing source for this provider.
    var pricingSourceLocalizationKey: String? { get }
    /// Clickable source URL for this provider's pricing page.
    var pricingSourceURL: URL? { get }
    /// Localization key used after a successful remote pricing refresh.
    var pricingUpdatedLocalizationKey: String? { get }
    /// Localization key describing where this provider's credentials are read from.
    var credentialHintLocalizationKey: String? { get }
    /// Whether the provider needs a full rescan whenever any watched file changes.
    var alwaysRescanOnFileChanges: Bool { get }

    func resolvedProjectPath(for session: Session) -> String
    func scanSessions() -> [Session]
    func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)?
    func changedSessionIds(for changedPaths: Set<String>) -> Set<String>

    func parseQuickStats(at path: String) -> SessionQuickStats
    func parseSession(at path: String) -> SessionStats
    func parseMessages(at path: String) -> [TranscriptDisplayMessage]
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage]
    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint]

    func openNewSession(_ session: Session)
    func resumeSession(_ session: Session)
    func openNewSession(inDirectory path: String)
    func resumeCommand(for session: Session) -> String

    func fetchProfile() async -> UserProfile?
}

extension SessionProvider {
    var usagePresentation: ProviderUsagePresentation {
        .standard
    }

    var credentialStatus: Bool? { nil }
    var statusLineInstaller: (any StatusLineInstalling)? { nil }
    var builtinPricingModels: [String: ModelPricing.Pricing] { [:] }
    var pricingFetcher: (any ProviderPricingFetching)? { nil }
    var pricingSourceLocalizationKey: String? { nil }
    var pricingSourceURL: URL? { nil }
    var pricingUpdatedLocalizationKey: String? { nil }
    var credentialHintLocalizationKey: String? { nil }
    var alwaysRescanOnFileChanges: Bool { false }
    func fetchProfile() async -> UserProfile? { nil }
    func changedSessionIds(for changedPaths: Set<String>) -> Set<String> {
        var changedIds: Set<String> = []
        for path in changedPaths {
            let fileName = (path as NSString).lastPathComponent
            guard fileName.hasSuffix(".jsonl") else { continue }
            changedIds.insert((fileName as NSString).deletingPathExtension)
        }
        return changedIds
    }

    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        parseMessages(at: path).compactMap { message in
            var parts: [String] = []
            if !message.text.isEmpty { parts.append(message.text) }
            if let toolName = message.toolName, !toolName.isEmpty { parts.append(toolName) }
            if let toolDetail = message.toolDetail, !toolDetail.isEmpty { parts.append(toolDetail) }
            if let oldString = message.editOldString, !oldString.isEmpty { parts.append(oldString) }
            if let newString = message.editNewString, !newString.isEmpty { parts.append(newString) }

            let content = SearchUtils.stripMarkdown(parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            guard content.count > 2 else { return nil }
            return SearchIndexMessage(role: message.role, content: content, timestamp: message.timestamp)
        }
    }

    /// Returns `true` when the provider's config directory exists.
    /// More reliable than PATH-based detection in sandboxed/Dock-launched macOS apps.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: configDirectory)
    }
}
