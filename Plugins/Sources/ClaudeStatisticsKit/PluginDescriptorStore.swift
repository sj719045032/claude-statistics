import Foundation

/// Thread-safe registry of provider-id → `ProviderDescriptor`,
/// populated by plugins at load time so the host's `ProviderKind`
/// fallback (`switch rawValue`) can dispatch to plugin-supplied
/// metadata without holding a hard-coded host static for every
/// extracted provider.
///
/// Why this exists: host UI surfaces (`StatusBarController` / `MenuBarFooter`
/// / `NotchPreferences` / etc.) reach for `kind.descriptor.<field>` —
/// `displayName`, `iconAssetName`, `accentColor`, `notchEnabledDefaultsKey`
/// and so on. Before a provider has been extracted those fields are
/// served by a host-side `ProviderDescriptor.<provider>` static. Once
/// the provider lives in `.csplugin` form the static is gone, but UI
/// code still wants the same metadata; the plugin pushes its
/// descriptor here on `init()` and the host's switch resolves through
/// the store as a fallback. Unit tests that exercise host UI paths
/// without loading the bundle register a placeholder in `setUp`.
///
/// Only one plugin per provider id at a time. Idempotent — re-register
/// replaces the previous entry (matching `PluginToolAliasStore`).
public enum PluginDescriptorStore {
    private static let lock = NSLock()
    private static var descriptors: [String: ProviderDescriptor] = [:]

    public static func register(_ descriptor: ProviderDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        descriptors[descriptor.id] = descriptor
    }

    public static func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        descriptors.removeValue(forKey: id)
    }

    public static func descriptor(for id: String) -> ProviderDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[id]
    }
}
