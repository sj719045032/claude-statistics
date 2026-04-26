import Foundation

/// Central runtime registry of all loaded plugins. Replaces the
/// closed-enum `ProviderRegistry` and the static `TerminalRegistry`
/// array — new plugins (Provider / Terminal / ShareRole /
/// ShareCardTheme) register themselves at startup, and the kernel
/// iterates the registry instead of `switch`-ing on a fixed enum.
///
/// Stage-3 introduces this type and its public API; stage 4 migrates
/// the kernel's existing `ProviderRegistry` and `TerminalRegistry`
/// look-ups to read from here. Until then the registry is constructed
/// but unused — the kernel keeps its current code paths.
@MainActor
public final class PluginRegistry {
    public init() {}

    /// Per-kind storage. Public read-only views are exposed as plain
    /// dictionaries so callers can iterate or look up by id without
    /// learning the registry's mutation API.
    public private(set) var providers:   [String: any Plugin] = [:]
    public private(set) var terminals:   [String: any Plugin] = [:]
    public private(set) var shareRoles:  [String: any Plugin] = [:]
    public private(set) var shareThemes: [String: any Plugin] = [:]

    /// Register a freshly-instantiated plugin. The registry stores it
    /// against `manifest.id` in the bucket(s) implied by `manifest.kind`.
    /// Re-registration with the same id throws — duplicate ids signal
    /// either a config mistake or a clash between two plugins claiming
    /// the same vendor namespace.
    public func register(_ plugin: any Plugin) throws {
        let manifest = type(of: plugin).manifest
        switch manifest.kind {
        case .provider:
            try insert(plugin, into: &providers, id: manifest.id, bucket: "provider")
        case .terminal:
            try insert(plugin, into: &terminals, id: manifest.id, bucket: "terminal")
        case .shareRole:
            try insert(plugin, into: &shareRoles, id: manifest.id, bucket: "shareRole")
        case .shareCardTheme:
            try insert(plugin, into: &shareThemes, id: manifest.id, bucket: "shareCardTheme")
        case .both:
            try insert(plugin, into: &providers, id: manifest.id, bucket: "provider")
            try insert(plugin, into: &terminals, id: manifest.id, bucket: "terminal")
        }
    }

    /// Snapshot of every loaded plugin's manifest. Useful for the
    /// Settings → Plugins panel and the load-report log.
    public func loadedManifests() -> [PluginManifest] {
        let all: [any Plugin] = Array(providers.values)
            + Array(terminals.values)
            + Array(shareRoles.values)
            + Array(shareThemes.values)
        // Dedup by id (a `.both` plugin shows up twice across buckets).
        var seen: Set<String> = []
        return all.compactMap { plugin in
            let manifest = type(of: plugin).manifest
            guard seen.insert(manifest.id).inserted else { return nil }
            return manifest
        }
    }

    private func insert(
        _ plugin: any Plugin,
        into bucket: inout [String: any Plugin],
        id: String,
        bucket bucketName: String
    ) throws {
        if bucket[id] != nil {
            throw PluginRegistryError.duplicateId(id: id, bucket: bucketName)
        }
        bucket[id] = plugin
    }
}

public enum PluginRegistryError: Error, CustomStringConvertible {
    case duplicateId(id: String, bucket: String)

    public var description: String {
        switch self {
        case .duplicateId(let id, let bucket):
            return "Plugin id '\(id)' already registered in '\(bucket)' bucket"
        }
    }
}
