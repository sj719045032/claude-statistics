import Foundation

/// Plugin contribution that backs the Usage tab — quota windows, dashboard
/// link, on-disk cache surface, and the credential-refresh affordance the
/// "Refresh" button calls when a session expires.
///
/// All work is async because the underlying API calls touch the network.
/// `loadCachedSnapshot` is the synchronous fast path used at app launch
/// and after window lookups, so the Usage view can paint immediately
/// while a background refresh runs.
public protocol ProviderUsageSource: Sendable {
    /// Web URL for this provider's usage / billing dashboard. Surfaced as
    /// a "Open in browser" link in the Usage view.
    var dashboardURL: URL? { get }

    /// On-disk path the host writes the latest snapshot to. Exposed so
    /// Settings can display the cache location and the user can clear it.
    var usageCacheFilePath: String? { get }

    func loadCachedSnapshot() -> ProviderUsageSnapshot?
    func refreshSnapshot() async throws -> ProviderUsageSnapshot

    /// Re-acquire credentials when the API rejects the current token.
    /// Default returns `false` so providers without an OAuth-style
    /// refresh flow simply opt out.
    func refreshCredentials() async -> Bool
}

extension ProviderUsageSource {
    public var dashboardURL: URL? { nil }
    public var usageCacheFilePath: String? { nil }

    public func refreshCredentials() async -> Bool { false }
}
