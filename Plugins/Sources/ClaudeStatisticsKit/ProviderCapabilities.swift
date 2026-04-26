import Foundation

/// Capability flags every Provider plugin declares. The host hides /
/// surfaces UI based on these — e.g. the Usage tab is only visible
/// when `supportsUsage` is true; the Settings → StatusLine block only
/// appears when `supportsStatusLine` is true.
public struct ProviderCapabilities: Codable, Equatable, Sendable {
    public let supportsCost: Bool
    public let supportsUsage: Bool
    public let supportsProfile: Bool
    public let supportsStatusLine: Bool
    public let supportsExactPricing: Bool
    public let supportsResume: Bool
    public let supportsNewSession: Bool

    public init(
        supportsCost: Bool,
        supportsUsage: Bool,
        supportsProfile: Bool,
        supportsStatusLine: Bool,
        supportsExactPricing: Bool,
        supportsResume: Bool,
        supportsNewSession: Bool
    ) {
        self.supportsCost = supportsCost
        self.supportsUsage = supportsUsage
        self.supportsProfile = supportsProfile
        self.supportsStatusLine = supportsStatusLine
        self.supportsExactPricing = supportsExactPricing
        self.supportsResume = supportsResume
        self.supportsNewSession = supportsNewSession
    }
}
