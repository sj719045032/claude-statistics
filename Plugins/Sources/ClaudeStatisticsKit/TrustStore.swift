import CryptoKit
import Foundation

/// Persistent record of the user's trust decisions for on-disk plugins.
///
/// The store maps a plugin's Info.plist hash + manifest id to one of
/// three states: `.allowed`, `.denied`, or `.unknown` (never asked).
/// `PluginLoader` calls `evaluate(...)` while walking the plugin
/// directory; `.allowed` lets the bundle load, `.denied` skips it,
/// and `.unknown` defers to the host's first-run prompt callback.
///
/// Q2 (no mandatory signing) means trust is the only gate between
/// "binary on disk" and "code in our process" — losing or
/// mis-persisting this file effectively quarantines every plugin
/// behind the prompt again, which is the correct fail-closed default.
public final class TrustStore: @unchecked Sendable {
    public enum Decision: String, Codable, Sendable {
        case allowed
        case denied
    }

    /// Where the trust file lives. Default:
    /// `~/Library/Application Support/Claude Statistics/trust.json`.
    public let storeURL: URL

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(storeURL: URL = TrustStore.defaultStoreURL) {
        self.storeURL = storeURL
        self.entries = Self.load(from: storeURL) ?? [:]
    }

    public static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Claude Statistics", isDirectory: true)
            .appendingPathComponent("trust.json")
    }

    /// Look up the persisted decision for a plugin. Hash is recomputed
    /// from the bundle's Info.plist so a swapped binary triggers a
    /// re-prompt even at the same path.
    public func decision(for manifest: PluginManifest, bundleURL: URL) -> Decision? {
        let key = makeKey(manifestId: manifest.id, hash: hash(of: bundleURL))
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.decision
    }

    /// Record a fresh decision and flush to disk. Idempotent.
    public func record(
        _ decision: Decision,
        for manifest: PluginManifest,
        bundleURL: URL
    ) {
        let pluginHash = hash(of: bundleURL)
        let key = makeKey(manifestId: manifest.id, hash: pluginHash)
        let entry = Entry(
            manifestId: manifest.id,
            pluginHash: pluginHash,
            decision: decision,
            recordedAt: Date()
        )
        lock.lock()
        entries[key] = entry
        let snapshot = entries
        lock.unlock()
        try? Self.save(snapshot, to: storeURL)
    }

    /// Drop every recorded decision. Used by the Settings panel when
    /// the user explicitly resets trust.
    public func clearAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Drop the persisted decision for one specific plugin. Called by
    /// the marketplace uninstaller so a previously-`.denied` decision
    /// doesn't haunt a reinstall — re-adding the same plugin should
    /// behave like a brand-new install (prompt or auto-allow per
    /// install path).
    public func removeEntry(for manifest: PluginManifest, bundleURL: URL) {
        let key = makeKey(manifestId: manifest.id, hash: hash(of: bundleURL))
        lock.lock()
        let existed = entries.removeValue(forKey: key) != nil
        let snapshot = entries
        lock.unlock()
        guard existed else { return }
        try? Self.save(snapshot, to: storeURL)
    }

    // MARK: - Internals

    private struct Entry: Codable {
        let manifestId: String
        let pluginHash: String
        let decision: Decision
        let recordedAt: Date
    }

    private func makeKey(manifestId: String, hash: String) -> String {
        "\(manifestId)|\(hash)"
    }

    /// SHA-256 of the bundle's Info.plist file. Cheap (kilobytes) and
    /// changes whenever the manifest does.
    private func hash(of bundleURL: URL) -> String {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func load(from url: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func save(_ entries: [String: Entry], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
    }
}
