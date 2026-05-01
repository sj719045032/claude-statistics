import Foundation

/// Pluggable per-(provider, endpoint) source of subscription data —
/// "what plan is this user on, how much quota have they consumed,
/// when does it reset?"
///
/// Why this is a separate protocol from `AccountProvider`/`UsageProvider`:
/// the same provider (e.g. Claude) can have multiple subscription
/// data sources depending on which `*_BASE_URL` the user pointed
/// the CLI at. Anthropic OAuth, GLM Coding Plan, and OpenRouter
/// credits all answer the same UI question with different APIs —
/// the host routes to whichever adapter matches the active host.
///
/// Lives in the SDK so a third-party `.csplugin` can ship its own
/// adapter without depending on host-only types. Plugins return
/// adapters from `ProviderPlugin.makeSubscriptionAdapters()`.
public protocol SubscriptionAdapter: Sendable {
    /// Display name for the adapter itself (not the user's plan).
    /// Shown e.g. in Settings → "Subscription source: GLM Coding Plan".
    var displayName: String { get }

    /// Provider this adapter answers for. Matches `ProviderDescriptor.id`
    /// for builtin providers ("claude", "codex", "gemini") so the
    /// router can pair an adapter with the right provider's endpoint
    /// detection.
    var providerID: String { get }

    /// Hosts (extracted from the active base URL) that should route to
    /// this adapter. Use the literal `"default"` to mean "matches when
    /// the user has set no custom base URL" — i.e. the official
    /// endpoint for this provider.
    var matchingHosts: [String] { get }

    /// Fetch the current subscription snapshot. Throws on transient
    /// failure; the host surfaces a "Couldn't fetch subscription"
    /// banner and falls back to cached data.
    func fetchSubscription(context: SubscriptionContext) async throws -> SubscriptionInfo

    /// Adapter-owned account manager. Returning a manager means
    /// "this adapter has its own list of identities (tokens) that
    /// the host's identity picker should show, and switching among
    /// them changes the live endpoint." Returning `nil` means "no
    /// per-account state — fall back to the provider's
    /// `EndpointDetector` (sync from CLI settings)."
    ///
    /// `@MainActor` so plugins can construct `ObservableObject`
    /// instances safely. Host invokes this once per plugin load and
    /// keeps the resulting manager for the process lifetime.
    @MainActor
    func makeAccountManager() -> SubscriptionAccountManager?
}

extension SubscriptionAdapter {
    @MainActor
    public func makeAccountManager() -> SubscriptionAccountManager? { nil }
}

/// Inputs the host hands an adapter when invoking it. Carries
/// whatever the host already extracted from the provider's settings
/// — adapters never reach for environment / files themselves so the
/// permission surface stays narrow.
public struct SubscriptionContext: Sendable {
    public let providerID: String
    public let baseURL: URL?
    public let apiKey: String?

    public init(providerID: String, baseURL: URL?, apiKey: String?) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}
