import Foundation
import ClaudeStatisticsKit

protocol SessionWatcher: AnyObject {
    func start()
    func stop()
}

// ProviderUsageDisplayMode, ProviderUsageWindowPresentation,
// ProviderUsageTrendPresentation, ProviderUsagePresentation, and the
// MenuBarStrip helpers all live in ClaudeStatisticsKit.

struct ProviderUsageSnapshot {
    let data: UsageData
    let fetchedAt: Date
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

// StatusLineLegendItem and StatusLineLegendSection live in ClaudeStatisticsKit.

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

// MARK: - Capability protocols
//
// `SessionProvider` is split into 5 narrow protocols by capability so
// consumers can depend on only what they need. The composition typealias
// at the bottom preserves the old `SessionProvider` name and keeps every
// existing call site working without change.

/// Identity, scanning, watching and parsing of session files.
protocol SessionDataProvider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }
    /// The provider's config directory path (e.g. `~/.claude`). Used to detect installation.
    var configDirectory: String { get }
    /// Whether the provider needs a full rescan whenever any watched file changes.
    var alwaysRescanOnFileChanges: Bool { get }

    func resolvedProjectPath(for session: Session) -> String
    func scanSessions() -> [Session]
    func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)?
    func changedSessionIds(for changedPaths: Set<String>) -> Set<String>
    func shouldRescanSessions(for changedPaths: Set<String>) -> Bool

    func parseQuickStats(at path: String) -> SessionQuickStats
    func parseSession(at path: String) -> SessionStats
    func parseMessages(at path: String) -> [TranscriptDisplayMessage]
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage]
    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint]
}

/// Usage windows / quotas + pricing.
protocol UsageProvider: Sendable {
    var usagePresentation: ProviderUsagePresentation { get }
    var usageSource: (any ProviderUsageSource)? { get }
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

    func menuBarStripSegments(from usage: UsageData?) -> [MenuBarStripSegment]
}

/// Credentials + profile fetch. Currently part of the `SessionProvider`
/// composition because every provider implements it, but defined as its
/// own protocol so consumers that only need profile data can narrow to
/// `any AccountProvider`.
protocol AccountProvider: Sendable {
    /// Whether stored credentials exist. `nil` means the check is not applicable for this provider.
    var credentialStatus: Bool? { get }
    /// Localization key describing where this provider's credentials are read from.
    var credentialHintLocalizationKey: String? { get }
    func fetchProfile() async -> UserProfile?
}

/// Notch hook + statusline installation.
protocol HookProvider: Sendable {
    /// Returns the statusline installer for this provider, or `nil` if not supported.
    var statusLineInstaller: (any StatusLineInstalling)? { get }
    /// Returns the notch hook installer for this provider, or `nil` if the
    /// provider has no notch hook support yet.
    var notchHookInstaller: (any HookInstalling)? { get }
    /// Subset of `NotchEventKind` this provider can actually emit. UI hides
    /// filters for events not in this set so toggling has no silent no-op.
    var supportedNotchEvents: Set<NotchEventKind> { get }
}

/// Launching / resuming sessions in their native CLI / terminal.
protocol SessionLauncher: Sendable {
    var displayName: String { get }
    func openNewSession(_ session: Session)
    func resumeSession(_ session: Session)
    func openNewSession(inDirectory path: String)
    func resumeCommand(for session: Session) -> String
}

/// Composition preserving the historical `SessionProvider` API surface.
/// Consumers needing every capability still use `any SessionProvider`;
/// consumers that only need a slice should depend on the narrow protocol
/// directly (e.g. `any UsageProvider`).
typealias SessionProvider =
    SessionDataProvider & UsageProvider & AccountProvider & HookProvider & SessionLauncher

// MARK: - Default implementations

extension SessionDataProvider {
    var alwaysRescanOnFileChanges: Bool { false }

    func changedSessionIds(for changedPaths: Set<String>) -> Set<String> {
        var changedIds: Set<String> = []
        for path in changedPaths {
            let fileName = (path as NSString).lastPathComponent
            guard fileName.hasSuffix(".jsonl") else { continue }
            changedIds.insert((fileName as NSString).deletingPathExtension)
        }
        return changedIds
    }

    func shouldRescanSessions(for changedPaths: Set<String>) -> Bool {
        alwaysRescanOnFileChanges
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

extension UsageProvider {
    var usagePresentation: ProviderUsagePresentation { .standard }
    var builtinPricingModels: [String: ModelPricing.Pricing] { [:] }
    var pricingFetcher: (any ProviderPricingFetching)? { nil }
    var pricingSourceLocalizationKey: String? { nil }
    var pricingSourceURL: URL? { nil }
    var pricingUpdatedLocalizationKey: String? { nil }

    /// Short rotating segments shown in the multi-provider menu bar strip.
    /// Each segment is one "page" that rotates every few seconds alongside
    /// the provider's icon. Default implementation derives sensible
    /// segments from `usagePresentation.menuBarMetric`; providers can
    /// override for custom behaviour.
    ///
    /// All segments reflect *used* percentage so colour thresholds and
    /// comparisons behave the same across providers. Gemini's buckets
    /// expose remaining percentage natively; we invert it here.
    func menuBarStripSegments(from usage: UsageData?) -> [MenuBarStripSegment] {
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

extension AccountProvider {
    var credentialStatus: Bool? { nil }
    var credentialHintLocalizationKey: String? { nil }
    func fetchProfile() async -> UserProfile? { nil }
}

extension HookProvider {
    var statusLineInstaller: (any StatusLineInstalling)? { nil }
    var notchHookInstaller: (any HookInstalling)? { nil }
    var supportedNotchEvents: Set<NotchEventKind> { [] }
}
