import Foundation

/// Credentials + profile fetch contributed by a Provider plugin.
/// Defined as its own narrow protocol so consumers that only need
/// profile data (e.g. the host's profile sidebar) can narrow to
/// `any AccountProvider` rather than carrying every SessionProvider
/// capability around. Most plugins implement it via the composed
/// `ProviderPlugin.makeAccountProvider()` factory; some plugins (e.g.
/// Codex's locally-decoded profile) implement it inline on the
/// provider object itself.
public protocol AccountProvider: Sendable {
    /// Whether stored credentials exist. `nil` means the check is not
    /// applicable for this provider — the host shows neither
    /// "logged in" nor "logged out" state.
    var credentialStatus: Bool? { get }
    /// Localization key describing where this provider's credentials
    /// are read from (rendered in Settings → Account → "Credentials
    /// from …").
    var credentialHintLocalizationKey: String? { get }
    func fetchProfile() async -> UserProfile?
}

extension AccountProvider {
    public var credentialStatus: Bool? { nil }
    public var credentialHintLocalizationKey: String? { nil }
    public func fetchProfile() async -> UserProfile? { nil }
}
