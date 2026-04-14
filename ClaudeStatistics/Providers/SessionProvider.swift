import Foundation

protocol SessionWatcher: AnyObject {
    func start()
    func stop()
}

struct ProviderUsageSnapshot {
    let data: UsageData
    let fetchedAt: Date
}

protocol ProviderUsageSource {
    var dashboardURL: URL? { get }

    func loadCachedSnapshot() -> ProviderUsageSnapshot?
    func refreshSnapshot() async throws -> ProviderUsageSnapshot
    func refreshCredentials() async -> Bool
}

extension ProviderUsageSource {
    var dashboardURL: URL? { nil }

    func refreshCredentials() async -> Bool {
        false
    }
}

protocol ProviderPricingFetching {
    func fetchPricing() async throws -> [String: ModelPricing.Pricing]
}

/// Encapsulates statusline install/restore operations for a specific provider.
/// Title and description localization keys are plain strings to avoid SwiftUI import.
protocol StatusLineInstalling {
    var isInstalled: Bool { get }
    /// Whether a restore/rollback option is available
    var hasRestoreOption: Bool { get }
    var titleLocalizationKey: String { get }
    var descriptionLocalizationKey: String { get }
    func install() throws
    func restore() throws
}

extension StatusLineInstalling {
    var hasRestoreOption: Bool { false }
    func restore() throws {}
}

protocol SessionProvider: Sendable {
    var kind: ProviderKind { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
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

    func resolvedProjectPath(for session: Session) -> String
    func scanSessions() -> [Session]
    func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)?

    func parseQuickStats(at path: String) -> SessionQuickStats
    func parseSession(at path: String) -> SessionStats
    func parseMessages(at path: String) -> [TranscriptDisplayMessage]
    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint]

    func openNewSession(_ session: Session)
    func resumeSession(_ session: Session)
    func openNewSession(inDirectory path: String)

    func fetchProfile() async -> UserProfile?
}

extension SessionProvider {
    var credentialStatus: Bool? { nil }
    var statusLineInstaller: (any StatusLineInstalling)? { nil }
    var builtinPricingModels: [String: ModelPricing.Pricing] { [:] }
    var pricingFetcher: (any ProviderPricingFetching)? { nil }
    var pricingSourceLocalizationKey: String? { nil }
    var pricingSourceURL: URL? { nil }
    var pricingUpdatedLocalizationKey: String? { nil }
    func fetchProfile() async -> UserProfile? { nil }

    /// Returns `true` when the provider's config directory exists.
    /// More reliable than PATH-based detection in sandboxed/Dock-launched macOS apps.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: configDirectory)
    }
}
