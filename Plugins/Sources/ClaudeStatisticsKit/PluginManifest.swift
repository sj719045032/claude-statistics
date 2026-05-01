import Foundation

/// What a plugin contributes to the host. A plugin may be more than one
/// kind (`.both` for now reserved for combined Provider+Terminal plugins
/// such as a vendor-specific editor adapter that ships both the CLI
/// integration and the terminal-side launcher).
public enum PluginKind: String, Codable, Sendable {
    /// Vendor adapter for an AI coding CLI (Claude / Codex / Gemini / …).
    case provider
    /// Terminal-emulator adapter for focus return + launching new sessions.
    case terminal
    /// Contributes share-card roles and their scoring functions.
    case shareRole
    /// Contributes share-card visual templates.
    case shareCardTheme
    /// Combined Provider + Terminal (rare; e.g. an editor that ships both).
    case both
    /// Adds a third-party subscription endpoint (GLM Coding Plan,
    /// OpenRouter, Kimi, …) that piggy-backs on an existing
    /// provider's CLI. The plugin contributes a `SubscriptionAdapter`
    /// + optionally a `SubscriptionAccountManager`; it does NOT bring
    /// its own `ProviderDescriptor` (the user is still using the
    /// host provider's CLI, just pointed at a different base URL).
    case subscriptionExtension
}

/// Coarse permission a plugin declares up front. The host shows these to
/// the user when prompting for trust on first load and gates risky calls
/// at runtime. Coarser than POSIX capabilities on purpose — fine-grained
/// sandboxing is a non-goal (REWRITE_PLAN §7.2).
public enum PluginPermission: String, Codable, Sendable, Hashable {
    /// Read/write under `~` (home directory subtree).
    case filesystemHome
    /// Read/write any path. High-risk; default deny.
    case filesystemAny
    /// Open outbound network connections.
    case network
    /// Use macOS Accessibility (AX) APIs.
    case accessibility
    /// Run AppleScript / OSA.
    case appleScript
    /// Access the macOS Keychain via Security framework.
    case keychain
}

/// User-facing categorisation orthogonal to `PluginKind`. The Settings
/// → Plugins → Discover panel groups catalog entries by this field —
/// users browse by "what does this do for me" rather than by which
/// runtime protocol the plugin implements. See
/// `docs/PLUGIN_MARKETPLACE.md` §3 for the full rationale.
///
/// Modeled as plain string constants instead of an enum so third-party
/// plugins (and a future catalog) can introduce categories without an
/// SDK release. The host UI maps each known string to a localized
/// display name and SF Symbol; unknown strings fall back to
/// `utility`.
public enum PluginCatalogCategory {
    /// Provider adapter for an AI coding CLI (Claude / Codex / Gemini /
    /// Aider / …). Matches the SDK protocol naming
    /// (`ProviderPlugin` / `ProviderDescriptor` / `ProviderRegistry`).
    public static let provider = "provider"
    /// Terminal-emulator adapter (focus return + launching).
    public static let terminal = "terminal"
    /// Desktop chat-app integration with deep-link focus
    /// (Claude.app / Codex.app / …).
    public static let chatApp = "chat-app"
    /// Share-card role scorers and visual themes.
    public static let shareCard = "share-card"
    /// Editor integration (VSCode / Cursor / Zed deep-link).
    public static let editorIntegration = "editor-integration"
    /// Subscription extension — third-party endpoint adapters
    /// (GLM Coding Plan, OpenRouter, Kimi, …) implementing
    /// `SubscriptionExtensionPlugin`. Distinct from `provider` because
    /// these plugins don't ship a CLI; they piggy-back on an existing
    /// provider's CLI by routing through a custom base URL and adding
    /// quota / token-management UI.
    public static let subscription = "subscription"
    /// Catch-all for tools that don't fit the buckets above.
    public static let utility = "utility"

    /// Every category recognised by the bundled host. Marketplace
    /// catalogs may publish additional values; the UI handles unknown
    /// strings by falling back to `utility`.
    public static let known: [String] = [
        provider, terminal, chatApp, shareCard, editorIntegration, subscription, utility
    ]

    /// Category to use when a plugin's manifest doesn't declare one
    /// explicitly. Derived from the plugin's `kind` so the Installed
    /// tab's filter bar groups plugins under the right chip even
    /// when the plugin author hasn't set a category. Returns
    /// `utility` for any future kind without a clear bucket.
    public static func fallback(forKind kind: PluginKind) -> String {
        switch kind {
        case .provider:               return provider
        case .terminal:               return terminal
        case .shareRole:              return shareCard
        case .shareCardTheme:         return shareCard
        case .both:                   return provider
        case .subscriptionExtension:  return subscription
        }
    }
}

/// Static metadata every plugin must publish. Loaded from
/// `manifest.json` inside the `.csplugin` bundle; for builtin plugins the
/// host reads the plugin type's `manifest` static directly without
/// touching disk.
public struct PluginManifest: Codable, Sendable, Equatable {
    /// Stable, globally-unique reverse-DNS identifier
    /// (e.g. `com.anthropic.claude` / `net.kovidgoyal.kitty`).
    public let id: String
    public let kind: PluginKind
    public let displayName: String
    public let version: SemVer
    /// Smallest SDK API version this plugin requires. The host loader
    /// rejects plugins whose required version exceeds the host's
    /// `SDKInfo.apiVersion`.
    public let minHostAPIVersion: SemVer
    public let permissions: [PluginPermission]
    /// Fully-qualified Swift class name used as the entry point. The
    /// loader looks the class up via `NSClassFromString` (Bundle mode)
    /// and casts it to `Plugin.Type`. Builtin plugins ignore this field.
    public let principalClass: String
    /// Optional bundle-relative resource name for the plugin's icon
    /// (24x24 template PDF preferred). `nil` falls back to a generic
    /// puzzle-piece glyph in the host UI.
    public let iconAsset: String?
    /// Optional user-facing category for the marketplace Discover
    /// panel. Conventionally one of `PluginCatalogCategory`'s
    /// constants, but third-party catalogs can ship arbitrary
    /// strings — unknown values fall back to `utility` in the UI.
    /// Backwards-compatible: existing `.csplugin` bundles without
    /// this field decode fine and show up under `utility`.
    public let category: String?

    public init(
        id: String,
        kind: PluginKind,
        displayName: String,
        version: SemVer,
        minHostAPIVersion: SemVer,
        permissions: [PluginPermission] = [],
        principalClass: String,
        iconAsset: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.version = version
        self.minHostAPIVersion = minHostAPIVersion
        self.permissions = permissions
        self.principalClass = principalClass
        self.iconAsset = iconAsset
        self.category = category
    }
}
