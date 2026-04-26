import Foundation

/// Persistent kill-switch for plugins, keyed by `manifest.id` only.
///
/// `TrustStore` answers "is this binary safe to load?" — it hashes the
/// bundle's Info.plist so a swapped binary triggers a re-prompt. That
/// model can't be used for host-resident plugins (no bundle, no hash)
/// and conflates two different user intents: trust verification vs.
/// "I want this plugin off".
///
/// `DisabledPluginsStore` is the second concept. A plugin id appears
/// here when the user clicked Disable in Settings; it stays in the set
/// until they click Enable (or Reset). Every source — `.host`,
/// `.bundled`, `.user` — consults this store the same way at startup,
/// so disable behaviour is uniform across them.
public final class DisabledPluginsStore: @unchecked Sendable {
    /// Where the disabled-set lives. Default:
    /// `~/Library/Application Support/Claude Statistics/disabled-plugins.json`.
    public let storeURL: URL

    private let lock = NSLock()
    private var ids: Set<String> = []

    public init(storeURL: URL = DisabledPluginsStore.defaultStoreURL) {
        self.storeURL = storeURL
        self.ids = Self.load(from: storeURL) ?? []
    }

    public static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Claude Statistics", isDirectory: true)
            .appendingPathComponent("disabled-plugins.json")
    }

    public func isDisabled(_ pluginId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(pluginId)
    }

    /// Flip the disabled flag for a plugin id and flush to disk.
    /// Idempotent — recording the same value twice is a no-op write.
    public func setDisabled(_ disabled: Bool, for pluginId: String) {
        lock.lock()
        let changed: Bool
        if disabled {
            changed = ids.insert(pluginId).inserted
        } else {
            changed = ids.remove(pluginId) != nil
        }
        let snapshot = ids
        lock.unlock()
        guard changed else { return }
        try? Self.save(snapshot, to: storeURL)
    }

    public func allDisabledIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    /// Drop every flag. Used by the Settings panel's "Reset" path so
    /// every previously-disabled plugin gets a chance to load again on
    /// the next launch.
    public func clearAll() {
        lock.lock()
        ids.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Internals

    private static func load(from url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(decoded)
    }

    private static func save(_ ids: Set<String>, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(ids).sorted())
        try data.write(to: url, options: .atomic)
    }
}
