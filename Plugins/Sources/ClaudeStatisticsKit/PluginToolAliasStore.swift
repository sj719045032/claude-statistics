import Foundation

/// Thread-safe registry of provider-id → tool-alias-table mappings,
/// populated by plugins at load time and consumed by host descriptors
/// (`ProviderDescriptor.resolveToolAlias`) without coupling to a
/// specific plugin's symbols.
///
/// Why this exists: a `ProviderDescriptor` is a `Sendable` struct
/// constructed once at startup, so its `resolveToolAlias` closure
/// can't capture a `@MainActor` `PluginRegistry`. Plugins still want
/// the host descriptor to delegate alias resolution back into the
/// plugin's own table (so the host doesn't need to ship a duplicate).
/// The store gives us a non-isolated, lock-protected hand-off path:
/// the plugin's `init()` registers its table, and any thread reading
/// the descriptor's closure can resolve through the store.
///
/// Plugins that don't need alias resolution (e.g. terminal plugins)
/// don't touch this. Builtin providers whose adapter still lives in
/// the host module (Claude / Codex today) keep their tables inline in
/// the descriptor closure — they don't need the store because the
/// alias enum is reachable from the closure's scope.
public enum PluginToolAliasStore {
    private static let lock = NSLock()
    private static var tables: [String: [String: String]] = [:]

    /// Plugin calls this once during `init()` to publish its alias
    /// table. The provider id is the same string the plugin reports
    /// in `ProviderDescriptor.id` / `ProviderHookNormalizing.hookProviderId`.
    public static func register(providerId: String, table: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        tables[providerId] = table
    }

    /// Drop a plugin's registration when the plugin is disabled or
    /// unloaded. Idempotent — unknown ids are silently ignored.
    public static func unregister(providerId: String) {
        lock.lock()
        defer { lock.unlock() }
        tables.removeValue(forKey: providerId)
    }

    /// Resolve `raw` against the registered table for `providerId`.
    /// Returns `nil` when the plugin hasn't registered or its table
    /// has no match. Callers fall back to the raw name in that case.
    public static func canonical(_ raw: String, for providerId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tables[providerId]?[raw]
    }
}
