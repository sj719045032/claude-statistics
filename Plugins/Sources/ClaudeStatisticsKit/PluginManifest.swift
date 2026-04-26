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
}

/// Coarse permission a plugin declares up front. The host shows these to
/// the user when prompting for trust on first load and gates risky calls
/// at runtime. Coarser than POSIX capabilities on purpose — fine-grained
/// sandboxing is a non-goal (REWRITE_PLAN §7.2).
public enum PluginPermission: String, Codable, Sendable, Hashable {
    /// Read/write under `~` (home directory subtree).
    case filesystemHome   = "filesystem.home"
    /// Read/write any path. High-risk; default deny.
    case filesystemAny    = "filesystem.any"
    /// Open outbound network connections.
    case network
    /// Use macOS Accessibility (AX) APIs.
    case accessibility
    /// Run AppleScript / OSA.
    case appleScript      = "apple.script"
    /// Access the macOS Keychain via Security framework.
    case keychain
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

    public init(
        id: String,
        kind: PluginKind,
        displayName: String,
        version: SemVer,
        minHostAPIVersion: SemVer,
        permissions: [PluginPermission] = [],
        principalClass: String,
        iconAsset: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.version = version
        self.minHostAPIVersion = minHostAPIVersion
        self.permissions = permissions
        self.principalClass = principalClass
        self.iconAsset = iconAsset
    }
}
