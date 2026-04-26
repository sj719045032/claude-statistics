import Foundation

/// A single row in the marketplace catalog (`index.json`'s
/// `entries[]`). Pure data — fetched by `PluginCatalog`, displayed by
/// the Settings → Plugins → Discover panel, and consumed by
/// `PluginInstaller` to download the right `.csplugin.zip` and verify
/// its contents.
///
/// Field semantics match `docs/PLUGIN_MARKETPLACE.md` §5.2. Treat this
/// type as the schema contract: bumping the layout breaks every
/// catalog repo in the wild.
public struct PluginCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    /// Reverse-DNS plugin identifier. **Must equal** the loaded
    /// `.csplugin`'s `manifest.id` after install — the installer
    /// rejects mismatches to prevent a catalog entry from
    /// impersonating an unrelated plugin.
    public let id: String
    /// Display name shown in the Discover row.
    public let name: String
    /// One-line description; longer content goes on the homepage.
    public let description: String
    public let author: String
    /// Optional project / docs URL. The detail row links here.
    public let homepage: URL?
    /// One of `PluginCatalogCategory`'s string constants. Unknown
    /// values fall back to `utility` in the UI.
    public let category: String
    /// Plugin's own SemVer. Compared against the installed
    /// manifest's version to flag "Update available".
    public let version: SemVer
    /// Smallest SDK API version this build requires; the host skips
    /// rows whose `minHostAPIVersion > SDKInfo.apiVersion`.
    public let minHostAPIVersion: SemVer
    /// HTTPS URL of the `.csplugin.zip` payload. Required to be
    /// reachable without auth (GitHub Releases recommended).
    public let downloadURL: URL
    /// Hex-encoded SHA-256 of the bytes at `downloadURL`. The
    /// installer rejects the bundle when the actual hash differs.
    public let sha256: String
    /// Optional 24x24 PNG/PDF for the row icon. `nil` falls back to
    /// the per-category SF Symbol.
    public let iconURL: URL?
    /// What the plugin asks the host to grant. Shown in the row
    /// detail; the host does not enforce these (M2 §7.2 chose no OS
    /// sandbox), the field is informational.
    public let permissions: [PluginPermission]
}

/// Top-level shape of `index.json`. `schemaVersion` lets the host
/// reject feeds emitted by an incompatible future version without
/// crashing on unknown fields.
public struct PluginCatalogIndex: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    /// ISO-8601 timestamp the catalog was last regenerated. Shown in
    /// the Discover panel's footer for "last updated".
    public let updatedAt: Date
    public let entries: [PluginCatalogEntry]

    /// `schemaVersion` value the host knows how to consume. Catalog
    /// servers may publish a higher value, in which case the host
    /// surfaces a "needs update" notice instead of attempting to
    /// decode.
    public static let supportedSchemaVersion = 1
}
