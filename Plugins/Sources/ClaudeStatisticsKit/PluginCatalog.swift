import Foundation

/// Fetches the marketplace `index.json` and decodes it into
/// `PluginCatalogIndex`. Fresh fetch on every call (catalog is small,
/// CDN-backed, and only invoked on user-initiated Discover opens —
/// see `docs/PLUGIN_MARKETPLACE.md` §4.1 for the rationale on why we
/// don't TTL-cache).
///
/// The local cache is **offline fallback only**: a successful fetch
/// writes the decoded payload back to disk so a subsequent call with
/// no network can still return *something*. The caller is told
/// whether the result is live or stale via the `Outcome.kind` case.
public actor PluginCatalog {
    /// Default catalog source — the public repo we maintain. Tests
    /// (and a future "self-host catalog" preference) override this
    /// via the initializer.
    public static let defaultRemoteURL = URL(
        string: "https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/index.json"
    )!

    /// On-disk fallback location:
    /// `~/Library/Application Support/Claude Statistics/catalog-cache.json`.
    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Claude Statistics", isDirectory: true)
            .appendingPathComponent("catalog-cache.json")
    }

    public enum FetchError: Error, Equatable {
        case network(String)
        case decoding(String)
        case schemaVersionTooNew(remote: Int, supported: Int)
        case offlineNoCache
    }

    /// Outcome of a fetch attempt. Discover panel reads `kind` to
    /// surface a "Live" / "Offline (cached)" badge.
    public struct Outcome: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case live
            case offlineFallback
        }
        public let index: PluginCatalogIndex
        public let kind: Kind
    }

    /// URLSession-shaped fetch hook so tests can inject a stub
    /// (`(URL) async throws -> Data`) without going to the network.
    public typealias DataLoader = @Sendable (URL) async throws -> Data

    public let remoteURL: URL
    public let cacheURL: URL
    private let loader: DataLoader

    public init(
        remoteURL: URL = PluginCatalog.defaultRemoteURL,
        cacheURL: URL = PluginCatalog.defaultCacheURL,
        loader: @escaping DataLoader = PluginCatalog.urlSessionLoader
    ) {
        self.remoteURL = remoteURL
        self.cacheURL = cacheURL
        self.loader = loader
    }

    /// Default loader uses URLSession.
    public static let urlSessionLoader: DataLoader = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.network("HTTP \(http.statusCode)")
        }
        return data
    }

    /// Fetch live → on success cache + return `.live`. On failure
    /// fall back to disk → return `.offlineFallback` if cache exists,
    /// throw `.offlineNoCache` if not.
    public func fetch() async throws -> Outcome {
        do {
            let data = try await loader(remoteURL)
            let index = try Self.decode(data)
            try? Self.writeCache(data, to: cacheURL)
            return Outcome(index: index, kind: .live)
        } catch let error as FetchError {
            // Decoding errors and schema mismatches are NOT network
            // problems — surface them so the user (or PR reviewer)
            // sees the real cause instead of an "offline" red
            // herring.
            if case .schemaVersionTooNew = error { throw error }
            if case .decoding = error { throw error }
            return try loadFromCache()
        } catch {
            return try loadFromCache()
        }
    }

    private func loadFromCache() throws -> Outcome {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL) else {
            throw FetchError.offlineNoCache
        }
        let index = try Self.decode(data)
        return Outcome(index: index, kind: .offlineFallback)
    }

    public static func decode(_ data: Data) throws -> PluginCatalogIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index: PluginCatalogIndex
        do {
            index = try decoder.decode(PluginCatalogIndex.self, from: data)
        } catch {
            throw FetchError.decoding(String(describing: error))
        }
        if index.schemaVersion > PluginCatalogIndex.supportedSchemaVersion {
            throw FetchError.schemaVersionTooNew(
                remote: index.schemaVersion,
                supported: PluginCatalogIndex.supportedSchemaVersion
            )
        }
        return index
    }

    static func writeCache(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
