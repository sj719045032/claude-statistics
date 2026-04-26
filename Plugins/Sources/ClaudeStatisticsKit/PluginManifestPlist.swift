import Foundation

/// Convenience helpers turning `PluginManifest` into / from the form
/// the host loader sees on disk: a `plist`-encoded dictionary embedded
/// inside a `.csplugin` bundle's `Info.plist` under the
/// `CSPluginManifest` key.
///
/// Builtin plugins skip this path entirely — the loader reads their
/// `static let manifest` directly. Only plugins arriving as on-disk
/// bundles need plist round-tripping.
extension PluginManifest {
    /// Info.plist key the loader reads when discovering a plugin.
    public static let infoDictionaryKey = "CSPluginManifest"

    /// Decode a manifest from raw `plist` data. Used by tests; the
    /// runtime path goes through `init(bundle:)`.
    public init(plistData: Data) throws {
        self = try PropertyListDecoder().decode(PluginManifest.self, from: plistData)
    }

    /// Decode a manifest from a bundle's Info.plist. Returns `nil` if
    /// the key is missing or the dictionary cannot be re-encoded into
    /// the manifest schema (typo'd field name, wrong value type, etc.).
    /// The loader treats that as "not a Claude Statistics plugin" and
    /// skips it — we never throw past the discovery boundary because
    /// one malformed bundle should not crash the host.
    public init?(bundle: Bundle, key: String = PluginManifest.infoDictionaryKey) {
        guard let raw = bundle.object(forInfoDictionaryKey: key) else { return nil }
        // Round-trip through PropertyListSerialization so the value
        // (which Bundle returns as `Any`) lands as `Data` we can feed
        // to PropertyListDecoder.
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: raw,
            format: .binary,
            options: 0
        ) else { return nil }
        guard let decoded = try? PropertyListDecoder().decode(PluginManifest.self, from: data) else {
            return nil
        }
        self = decoded
    }

    /// Encode the manifest as a `plist` dictionary suitable for embedding
    /// in a `.csplugin` Info.plist. Plugin packagers (and tests) call
    /// this when generating the bundle's Info.plist.
    public func encodedAsPlistDictionary() throws -> [String: Any] {
        let data = try PropertyListEncoder().encode(self)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dict = plist as? [String: Any] else {
            throw PluginManifestPlistError.notADictionary
        }
        return dict
    }
}

public enum PluginManifestPlistError: Error, CustomStringConvertible {
    case notADictionary

    public var description: String {
        switch self {
        case .notADictionary:
            return "PluginManifest plist encoding did not produce a top-level dictionary"
        }
    }
}
