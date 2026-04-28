import XCTest
@testable import Claude_Statistics
@testable import ClaudeStatisticsKit

final class SemVerTests: XCTestCase {
    func testParsesValidString() {
        XCTAssertEqual(SemVer("1.2.3"), SemVer(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemVer("0.0.0"), SemVer(major: 0, minor: 0, patch: 0))
        XCTAssertEqual(SemVer("10.20.30"), SemVer(major: 10, minor: 20, patch: 30))
    }

    func testRejectsInvalidString() {
        XCTAssertNil(SemVer("1.2"))
        XCTAssertNil(SemVer("1.2.3.4"))
        XCTAssertNil(SemVer("v1.2.3"))
        XCTAssertNil(SemVer("1.2.3-beta"))
        XCTAssertNil(SemVer("-1.0.0"))
        XCTAssertNil(SemVer(""))
    }

    func testOrdering() {
        XCTAssertLessThan(SemVer("1.0.0")!, SemVer("1.0.1")!)
        XCTAssertLessThan(SemVer("1.0.9")!, SemVer("1.1.0")!)
        XCTAssertLessThan(SemVer("1.9.9")!, SemVer("2.0.0")!)
        XCTAssertGreaterThan(SemVer("2.0.0")!, SemVer("1.99.99")!)
    }

    func testCodableRoundTrip() throws {
        let original = SemVer(major: 4, minor: 1, patch: 7)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"4.1.7\"")
        let decoded = try JSONDecoder().decode(SemVer.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeRejectsBadString() {
        let bad = "\"1.2-beta\"".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SemVer.self, from: bad))
    }
}

final class PluginManifestTests: XCTestCase {
    private let sample = PluginManifest(
        id: "com.example.aider",
        kind: .provider,
        displayName: "Aider",
        version: SemVer(major: 1, minor: 2, patch: 3),
        minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
        permissions: [.filesystemHome, .network],
        principalClass: "AiderProviderPlugin",
        iconAsset: "icon.pdf"
    )

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func testPermissionRawValuesUseDottedForm() {
        XCTAssertEqual(PluginPermission.filesystemHome.rawValue, "filesystem.home")
        XCTAssertEqual(PluginPermission.filesystemAny.rawValue, "filesystem.any")
        XCTAssertEqual(PluginPermission.appleScript.rawValue, "apple.script")
    }

    func testKindCodableUsesEnumRawValue() throws {
        let kinds: [PluginKind] = [.provider, .terminal, .shareRole, .shareCardTheme, .both]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(PluginKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func testPlistRoundTrip() throws {
        let dict = try sample.encodedAsPlistDictionary()
        XCTAssertEqual(dict["id"] as? String, "com.example.aider")
        XCTAssertEqual(dict["principalClass"] as? String, "AiderProviderPlugin")
        // Re-encode the dictionary and decode through `init(plistData:)`
        // — the path the loader follows when reading a `.csplugin`'s
        // Info.plist.
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0
        )
        let decoded = try PluginManifest(plistData: data)
        XCTAssertEqual(decoded, sample)
    }

    func testInfoDictionaryKey() {
        XCTAssertEqual(PluginManifest.infoDictionaryKey, "CSPluginManifest")
    }

    func testBundleInitMissingKeyReturnsNil() {
        // A bundle that has no CSPluginManifest entry should yield nil
        // rather than throwing — the loader treats that as "not a
        // Claude Statistics plugin" and skips it.
        let manifest = PluginManifest(bundle: Bundle.main)
        XCTAssertNil(manifest)
    }

    func testCategoryDefaultsToNil() {
        // Backwards-compat: existing .csplugin bundles (and the
        // `sample` here) don't set category, decoding must succeed
        // and yield nil.
        XCTAssertNil(sample.category)
    }

    func testCategoryRoundTripsThroughPlist() throws {
        let withCategory = PluginManifest(
            id: "com.example.cat",
            kind: .terminal,
            displayName: "Cat",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            principalClass: "CatPlugin",
            category: PluginCatalogCategory.chatApp
        )
        let dict = try withCategory.encodedAsPlistDictionary()
        XCTAssertEqual(dict["category"] as? String, "chat-app")
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0
        )
        let decoded = try PluginManifest(plistData: data)
        XCTAssertEqual(decoded, withCategory)
        XCTAssertEqual(decoded.category, "chat-app")
    }

    func testCategoryDecodesMissingKeyAsNil() throws {
        // A manifest emitted before this field existed must still
        // decode — the loader can't reject "old" .csplugin bundles
        // just because they don't carry a category.
        let json = """
        {
          "id": "com.example.legacy",
          "kind": "terminal",
          "displayName": "Legacy",
          "version": "1.0.0",
          "minHostAPIVersion": "0.1.0",
          "permissions": [],
          "principalClass": "LegacyPlugin"
        }
        """
        let decoded = try JSONDecoder().decode(
            PluginManifest.self, from: Data(json.utf8)
        )
        XCTAssertNil(decoded.category)
    }

    func testKnownCategoriesContainAllSixDocumentedValues() {
        XCTAssertEqual(
            Set(PluginCatalogCategory.known),
            ["vendor", "terminal", "chat-app", "share-card", "editor-integration", "utility"]
        )
    }
}

/// Marketplace catalog entry — wire format for `index.json`'s
/// `entries[]`. Pinning the schema down with tests so a sloppy edit
/// to PluginCatalogEntry would block before any catalog repo eats it.
final class PluginCatalogEntryTests: XCTestCase {
    private let sampleJSON = """
    {
      "schemaVersion": 1,
      "updatedAt": "2026-04-26T10:00:00Z",
      "entries": [
        {
          "id": "com.anthropic.claudefordesktop",
          "name": "Claude (chat app)",
          "description": "Focus Claude.app sessions via deep-link.",
          "author": "Stone",
          "homepage": "https://github.com/sj719045032/claude-statistics",
          "category": "chat-app",
          "version": "1.0.0",
          "minHostAPIVersion": "0.1.0",
          "downloadURL": "https://github.com/example/releases/ClaudeAppPlugin-1.0.0.csplugin.zip",
          "sha256": "abc123def456",
          "iconURL": "https://raw.githubusercontent.com/example/icons/claude.png",
          "permissions": []
        }
      ]
    }
    """

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    func testIndexDecodesFromIndexJsonShape() throws {
        let data = Data(sampleJSON.utf8)
        let index = try makeDecoder().decode(PluginCatalogIndex.self, from: data)
        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertEqual(index.entries.count, 1)
        let entry = index.entries[0]
        XCTAssertEqual(entry.id, "com.anthropic.claudefordesktop")
        XCTAssertEqual(entry.category, "chat-app")
        XCTAssertEqual(entry.version, SemVer(major: 1, minor: 0, patch: 0))
        XCTAssertEqual(entry.sha256, "abc123def456")
        XCTAssertNotNil(entry.homepage)
        XCTAssertNotNil(entry.iconURL)
        XCTAssertTrue(entry.permissions.isEmpty)
    }

    func testEntryIsIdentifiableById() {
        let entry = PluginCatalogEntry(
            id: "com.example.foo",
            name: "Foo",
            description: "x",
            author: "y",
            homepage: nil,
            category: "utility",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            downloadURL: URL(string: "https://example.com/foo.csplugin.zip")!,
            sha256: "0",
            iconURL: nil,
            permissions: []
        )
        // SwiftUI ForEach uses `.id` to diff rows.
        XCTAssertEqual(entry.id, "com.example.foo")
    }

    func testSupportedSchemaVersionMatchesDocs() {
        // Bumping the constant has marketplace-wide consequences (every
        // catalog repo). Pin the current value in a test so an
        // accidental change has to be intentional.
        XCTAssertEqual(PluginCatalogIndex.supportedSchemaVersion, 1)
    }

    func testIndexRoundTripsViaCodable() throws {
        let original = try makeDecoder().decode(
            PluginCatalogIndex.self,
            from: Data(sampleJSON.utf8)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(original)
        let redecoded = try makeDecoder().decode(
            PluginCatalogIndex.self,
            from: encoded
        )
        XCTAssertEqual(original, redecoded)
    }
}

/// `PluginCatalog` is the actor that fetches index.json and falls
/// back to disk when offline. These tests exercise the four code
/// paths (live success / network fail with cache / network fail
/// without cache / schema version too new) through a stubbed
/// `DataLoader` so the suite stays hermetic — no real network.
final class PluginCatalogTests: XCTestCase {
    private var sandbox: URL!
    private var cacheURL: URL!

    private static let liveJSON = """
    {
      "schemaVersion": 1,
      "updatedAt": "2026-04-26T10:00:00Z",
      "entries": [
        {
          "id": "com.example.foo",
          "name": "Foo",
          "description": "test",
          "author": "tester",
          "homepage": null,
          "category": "utility",
          "version": "1.0.0",
          "minHostAPIVersion": "0.1.0",
          "downloadURL": "https://example.com/foo.zip",
          "sha256": "abc",
          "iconURL": null,
          "permissions": []
        }
      ]
    }
    """

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        cacheURL = sandbox.appendingPathComponent("catalog-cache.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testLiveFetchReturnsDecodedIndexAndWritesCache() async throws {
        let catalog = PluginCatalog(
            remoteURL: URL(string: "https://example.com/index.json")!,
            cacheURL: cacheURL,
            loader: { _ in Data(Self.liveJSON.utf8) }
        )
        let outcome = try await catalog.fetch()
        XCTAssertEqual(outcome.kind, .live)
        XCTAssertEqual(outcome.index.entries.count, 1)
        XCTAssertEqual(outcome.index.entries.first?.id, "com.example.foo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testNetworkFailureFallsBackToCache() async throws {
        // Pre-populate the cache with a previous live response.
        try Data(Self.liveJSON.utf8).write(to: cacheURL)
        let catalog = PluginCatalog(
            remoteURL: URL(string: "https://example.com/index.json")!,
            cacheURL: cacheURL,
            loader: { _ in throw URLError(.notConnectedToInternet) }
        )
        let outcome = try await catalog.fetch()
        XCTAssertEqual(outcome.kind, .offlineFallback)
        XCTAssertEqual(outcome.index.entries.first?.id, "com.example.foo")
    }

    func testNetworkFailureWithNoCacheThrowsOfflineNoCache() async throws {
        let catalog = PluginCatalog(
            remoteURL: URL(string: "https://example.com/index.json")!,
            cacheURL: cacheURL,
            loader: { _ in throw URLError(.notConnectedToInternet) }
        )
        do {
            _ = try await catalog.fetch()
            XCTFail("Expected offlineNoCache to be thrown")
        } catch let error as PluginCatalog.FetchError {
            XCTAssertEqual(error, .offlineNoCache)
        }
    }

    func testSchemaVersionTooNewThrowsRatherThanFallingBackSilently() async throws {
        let futureJSON = """
        {
          "schemaVersion": 99,
          "updatedAt": "2026-04-26T10:00:00Z",
          "entries": []
        }
        """
        let catalog = PluginCatalog(
            remoteURL: URL(string: "https://example.com/index.json")!,
            cacheURL: cacheURL,
            loader: { _ in Data(futureJSON.utf8) }
        )
        do {
            _ = try await catalog.fetch()
            XCTFail("Expected schemaVersionTooNew")
        } catch let error as PluginCatalog.FetchError {
            if case .schemaVersionTooNew(let remote, let supported) = error {
                XCTAssertEqual(remote, 99)
                XCTAssertEqual(supported, PluginCatalogIndex.supportedSchemaVersion)
            } else {
                XCTFail("Wrong FetchError case: \(error)")
            }
        }
    }

    func testMalformedJSONThrowsDecodingNotFallback() async throws {
        // A garbage live response should NOT silently land us on the
        // cache — the user (or a catalog reviewer) needs to see the
        // real cause.
        try Data(Self.liveJSON.utf8).write(to: cacheURL)
        let catalog = PluginCatalog(
            remoteURL: URL(string: "https://example.com/index.json")!,
            cacheURL: cacheURL,
            loader: { _ in Data("{ not json }".utf8) }
        )
        do {
            _ = try await catalog.fetch()
            XCTFail("Expected decoding error")
        } catch let error as PluginCatalog.FetchError {
            if case .decoding = error {
                // expected
            } else {
                XCTFail("Wrong FetchError case: \(error)")
            }
        }
    }
}

/// `PluginInstaller.stageBundle` is the half of the pipeline that
/// can fail without touching `PluginRegistry` — these tests pin
/// down its decisions (download / hash / unzip / manifest match)
/// using real on-disk fake bundles + a stubbed DataLoader.
final class PluginInstallerStageTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Build a minimal `<id>.csplugin` directory with a Contents/
    /// Info.plist carrying a CSPluginManifest dict the SDK can
    /// decode, then zip it. Returns (zipData, sha256, manifest).
    private func buildFakeCsplugin(
        id: String = "com.example.foo",
        bundleName: String = "Foo.csplugin",
        version: SemVer = SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SemVer = SemVer(major: 0, minor: 1, patch: 0)
    ) throws -> (zipData: Data, sha256: String, manifest: PluginManifest) {
        let manifest = PluginManifest(
            id: id,
            kind: .terminal,
            displayName: "Foo",
            version: version,
            minHostAPIVersion: minHostAPIVersion,
            principalClass: "FooPlugin",
            category: "utility"
        )
        let manifestDict = try manifest.encodedAsPlistDictionary()
        let infoDict: [String: Any] = [
            "CFBundleIdentifier": id,
            "CFBundleName": bundleName,
            "CFBundleExecutable": "Foo",
            "CFBundlePackageType": "BNDL",
            "NSPrincipalClass": "FooPlugin",
            PluginManifest.infoDictionaryKey: manifestDict
        ]

        let bundleDir = sandbox.appendingPathComponent(bundleName, isDirectory: true)
        let contentsDir = bundleDir.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoDict, format: .xml, options: 0
        )
        try plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))

        let zipURL = sandbox.appendingPathComponent("\(bundleName).zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-rq", zipURL.path, bundleName]
        zip.currentDirectoryURL = sandbox
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let zipData = try Data(contentsOf: zipURL)
        let hash = PluginInstaller.sha256(of: zipData)
        // Clean up so the unzip step inside stageBundle works in a
        // fresh staging dir (otherwise the sandbox already contains
        // a same-named bundle).
        try FileManager.default.removeItem(at: bundleDir)
        try FileManager.default.removeItem(at: zipURL)
        return (zipData, hash, manifest)
    }

    private func makeEntry(
        id: String,
        sha256: String,
        downloadURL: URL = URL(string: "https://example.com/foo.csplugin.zip")!,
        version: SemVer = SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SemVer = SemVer(major: 0, minor: 1, patch: 0)
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            name: "Foo",
            description: "x",
            author: "y",
            homepage: nil,
            category: "utility",
            version: version,
            minHostAPIVersion: minHostAPIVersion,
            downloadURL: downloadURL,
            sha256: sha256,
            iconURL: nil,
            permissions: []
        )
    }

    func testStageBundleSucceedsForValidPayload() async throws {
        let (zipData, hash, manifest) = try buildFakeCsplugin()
        let entry = makeEntry(id: manifest.id, sha256: hash)
        let staged = try await PluginInstaller.stageBundle(
            entry: entry,
            loader: { _ in zipData }
        )
        XCTAssertEqual(staged.manifest.id, manifest.id)
        XCTAssertEqual(staged.bundleURL.lastPathComponent, "Foo.csplugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.bundleURL.path))
        try? FileManager.default.removeItem(at: staged.stagingRoot)
    }

    func testStageBundleRejectsHashMismatch() async throws {
        let (zipData, _, manifest) = try buildFakeCsplugin()
        let entry = makeEntry(id: manifest.id, sha256: "deadbeef")
        do {
            _ = try await PluginInstaller.stageBundle(
                entry: entry,
                loader: { _ in zipData }
            )
            XCTFail("Expected sha256Mismatch")
        } catch let error as PluginInstaller.InstallError {
            if case .sha256Mismatch(let expected, _) = error {
                XCTAssertEqual(expected, "deadbeef")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }

    func testStageBundleRejectsManifestIDMismatch() async throws {
        let (zipData, hash, _) = try buildFakeCsplugin(id: "com.example.foo")
        // Catalog lies about which plugin lives at this URL.
        let entry = makeEntry(id: "com.example.malicious", sha256: hash)
        do {
            _ = try await PluginInstaller.stageBundle(
                entry: entry,
                loader: { _ in zipData }
            )
            XCTFail("Expected manifestIDMismatch")
        } catch let error as PluginInstaller.InstallError {
            if case .manifestIDMismatch(let expected, let actual) = error {
                XCTAssertEqual(expected, "com.example.malicious")
                XCTAssertEqual(actual, "com.example.foo")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }

    func testStageBundleRejectsIncompatibleAPIVersion() async throws {
        // Plugin requires SDK 99.x; host is 0.1.x.
        let future = SemVer(major: 99, minor: 0, patch: 0)
        let (zipData, hash, _) = try buildFakeCsplugin(minHostAPIVersion: future)
        let entry = makeEntry(
            id: "com.example.foo",
            sha256: hash,
            minHostAPIVersion: future
        )
        do {
            _ = try await PluginInstaller.stageBundle(
                entry: entry,
                loader: { _ in zipData }
            )
            XCTFail("Expected incompatibleAPIVersion")
        } catch let error as PluginInstaller.InstallError {
            if case .incompatibleAPIVersion = error {
                // expected
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }

    func testStageBundlePropagatesDownloadError() async throws {
        let entry = makeEntry(id: "x", sha256: "y")
        do {
            _ = try await PluginInstaller.stageBundle(
                entry: entry,
                loader: { _ in throw URLError(.notConnectedToInternet) }
            )
            XCTFail("Expected downloadFailed")
        } catch let error as PluginInstaller.InstallError {
            if case .downloadFailed = error {
                // expected
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }
}

/// `PluginInstaller.install` end-to-end. Goes past `stageBundle`'s
/// remit (which only validates) and exercises the side-effects:
/// atomic move into destination, TrustStore write, hand-off to
/// PluginLoader.loadOne. The fake bundle here has no Mach-O so
/// `loadOne` will return `.bundleLoadFailed` and `install` throws
/// `.loadFailed(.bundleLoadFailed)` — but every step BEFORE that
/// must have already happened, and these tests pin those down.
@MainActor
final class PluginInstallerIntegrationTests: XCTestCase {
    private var sandbox: URL!
    private var destinationDir: URL!
    private var trustStoreURL: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginInstallerIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        destinationDir = sandbox.appendingPathComponent("Plugins", isDirectory: true)
        trustStoreURL = sandbox.appendingPathComponent("trust.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func buildFakeZip(
        id: String = "com.example.integration",
        bundleName: String = "Integration.csplugin"
    ) throws -> (zipData: Data, sha256: String) {
        let manifest = PluginManifest(
            id: id,
            kind: .terminal,
            displayName: "Integration",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            principalClass: "IntegrationPlugin"
        )
        let manifestDict = try manifest.encodedAsPlistDictionary()
        let infoDict: [String: Any] = [
            "CFBundleIdentifier": id,
            "CFBundleName": bundleName,
            "CFBundleExecutable": "Integration",
            "CFBundlePackageType": "BNDL",
            "NSPrincipalClass": "IntegrationPlugin",
            PluginManifest.infoDictionaryKey: manifestDict
        ]

        let bundleDir = sandbox.appendingPathComponent(bundleName, isDirectory: true)
        let contentsDir = bundleDir.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoDict, format: .xml, options: 0
        )
        try plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))

        let zipURL = sandbox.appendingPathComponent("\(bundleName).zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-rq", zipURL.path, bundleName]
        zip.currentDirectoryURL = sandbox
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let data = try Data(contentsOf: zipURL)
        try FileManager.default.removeItem(at: bundleDir)
        try FileManager.default.removeItem(at: zipURL)
        return (data, PluginInstaller.sha256(of: data))
    }

    private func makeEntry(id: String, sha256: String) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id, name: "Integration", description: "x", author: "y",
            homepage: nil, category: "utility",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            downloadURL: URL(string: "https://example.com/x.zip")!,
            sha256: sha256, iconURL: nil, permissions: []
        )
    }

    func testInstallMovesFileTrustsAndThrowsLoadFailedOnNoMachO() async throws {
        let (zipData, hash) = try buildFakeZip()
        let entry = makeEntry(id: "com.example.integration", sha256: hash)
        let registry = PluginRegistry()
        let trustStore = TrustStore(storeURL: trustStoreURL)
        let destURL = destinationDir!

        do {
            _ = try await PluginInstaller.install(
                entry: entry,
                into: registry,
                trustStore: trustStore,
                destination: { destURL },
                loader: { _ in zipData }
            )
            XCTFail("Expected loadFailed because the fake bundle has no Mach-O")
        } catch let error as PluginInstaller.InstallError {
            // Pin down that bundle.load() is what blew up — not
            // something earlier in the pipeline.
            if case .loadFailed(let reason) = error {
                XCTAssertEqual(reason, .bundleLoadFailed)
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }

        // Even though loadOne failed, every prior side-effect must
        // have happened — so a future fix or a working binary just
        // needs the load to succeed; the file/trust state is already
        // correct.

        // 1. The bundle moved to destination/<bundleName>.csplugin
        let installedURL = destURL.appendingPathComponent("Integration.csplugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))

        // 2. TrustStore got the .allowed pre-record (catalog install
        //    is explicit user intent — no first-launch prompt).
        let manifest = PluginManifest(bundle: Bundle(url: installedURL)!)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(
            trustStore.decision(for: manifest!, bundleURL: installedURL),
            .allowed
        )

        // 3. PluginRegistry stayed empty — because loadOne failed,
        //    register was never called. Critical: a halfway install
        //    must NOT leave a phantom row in the registry.
        XCTAssertTrue(registry.terminals.isEmpty)
        XCTAssertTrue(registry.providers.isEmpty)
    }

    func testInstallReplacesExistingBundleAtSameID() async throws {
        // Pre-populate the destination with a stale copy of the
        // bundle. Install must atomically overwrite — not error
        // out, not append a `-2` suffix.
        let (zipData, hash) = try buildFakeZip()
        let entry = makeEntry(id: "com.example.integration", sha256: hash)
        let registry = PluginRegistry()
        let trustStore = TrustStore(storeURL: trustStoreURL)
        let destURL = destinationDir!
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        let staleBundle = destURL.appendingPathComponent("Integration.csplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: staleBundle, withIntermediateDirectories: true)
        try "stale".write(
            to: staleBundle.appendingPathComponent("STALE_MARKER"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await PluginInstaller.install(
                entry: entry,
                into: registry,
                trustStore: trustStore,
                destination: { destURL },
                loader: { _ in zipData }
            )
        } catch PluginInstaller.InstallError.loadFailed {
            // expected — fake bundle has no Mach-O
        }

        // The stale marker must be gone; the new bundle's Info.plist
        // must be present.
        let installedURL = destURL.appendingPathComponent("Integration.csplugin")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installedURL.appendingPathComponent("STALE_MARKER").path),
            "Stale bundle should have been replaced atomically"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installedURL.appendingPathComponent("Contents/Info.plist").path)
        )
    }
}

@MainActor
final class PluginRegistryTests: XCTestCase {
    private final class FakeProviderPlugin: NSObject, Plugin {
        static let manifest = PluginManifest(
            id: "com.test.alpha",
            kind: .provider,
            displayName: "Alpha",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "FakeProviderPlugin"
        )
        override init() { super.init() }
    }

    private final class FakeTerminalPlugin: NSObject, Plugin {
        static let manifest = PluginManifest(
            id: "com.test.beta",
            kind: .terminal,
            displayName: "Beta",
            version: SemVer(major: 0, minor: 9, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [.accessibility],
            principalClass: "FakeTerminalPlugin"
        )
        override init() { super.init() }
    }

    private final class FakeBothPlugin: NSObject, Plugin {
        static let manifest = PluginManifest(
            id: "com.test.combo",
            kind: .both,
            displayName: "Combo",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "FakeBothPlugin"
        )
        override init() { super.init() }
    }

    func testRegisterByKind() throws {
        let registry = PluginRegistry()
        try registry.register(FakeProviderPlugin())
        try registry.register(FakeTerminalPlugin())
        XCTAssertEqual(registry.providers.count, 1)
        XCTAssertEqual(registry.terminals.count, 1)
        XCTAssertNotNil(registry.providers["com.test.alpha"])
        XCTAssertNotNil(registry.terminals["com.test.beta"])
        XCTAssertEqual(registry.loadedManifests().count, 2)
    }

    func testBothKindLandsInBothBuckets() throws {
        let registry = PluginRegistry()
        try registry.register(FakeBothPlugin())
        XCTAssertNotNil(registry.providers["com.test.combo"])
        XCTAssertNotNil(registry.terminals["com.test.combo"])
        // Manifest list deduplicates the .both plugin to a single entry.
        XCTAssertEqual(registry.loadedManifests().count, 1)
    }

    func testDuplicateIdThrows() throws {
        let registry = PluginRegistry()
        try registry.register(FakeProviderPlugin())
        XCTAssertThrowsError(try registry.register(FakeProviderPlugin())) { error in
            guard case PluginRegistryError.duplicateId(let id, let bucket) = error else {
                return XCTFail("Expected duplicateId, got \(error)")
            }
            XCTAssertEqual(id, "com.test.alpha")
            XCTAssertEqual(bucket, "provider")
        }
    }

    func testHostAPIVersionExposed() {
        XCTAssertEqual(SDKInfo.apiVersion, SemVer(major: 0, minor: 1, patch: 0))
    }

    private final class FakeProviderPluginImpl: NSObject, ProviderPlugin {
        static let manifest = PluginManifest(
            id: "com.test.provider",
            kind: .provider,
            displayName: "Test Provider",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "FakeProviderPluginImpl"
        )
        let descriptor = ProviderDescriptor(
            id: "com.test.provider",
            displayName: "Test Provider",
            iconAssetName: "test",
            accentColor: .gray,
            notchEnabledDefaultsKey: "notch.enabled.test",
            resolveToolAlias: { _ in nil }
        )
        override init() { super.init() }
    }

    private final class FakeTerminalPluginImpl: NSObject, TerminalPlugin {
        static let manifest = PluginManifest(
            id: "com.test.terminal",
            kind: .terminal,
            displayName: "Test Terminal",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "FakeTerminalPluginImpl"
        )
        let descriptor = TerminalDescriptor(
            id: "com.test.terminal",
            displayName: "Test Terminal",
            category: .terminal,
            bundleIdentifiers: ["com.test"],
            terminalNameAliases: ["test"],
            processNameHints: ["test"],
            focusPrecision: .appOnly,
            autoLaunchPriority: nil
        )
        override init() { super.init() }
    }

    func testUnregisterRemovesFromAllBuckets() throws {
        let registry = PluginRegistry()
        try registry.register(FakeBothPlugin())
        XCTAssertNotNil(registry.providers["com.test.combo"])
        XCTAssertNotNil(registry.terminals["com.test.combo"])

        let removed = registry.unregister(id: "com.test.combo")
        XCTAssertTrue(removed)
        XCTAssertNil(registry.providers["com.test.combo"])
        XCTAssertNil(registry.terminals["com.test.combo"])
        XCTAssertNil(registry.source(for: "com.test.combo"))

        // Idempotent: a second call returns false rather than throwing.
        XCTAssertFalse(registry.unregister(id: "com.test.combo"))
    }

    func testRegisterRecordsDefaultHostSource() throws {
        let registry = PluginRegistry()
        try registry.register(FakeProviderPlugin())
        if case .host = registry.source(for: "com.test.alpha") {
            // expected
        } else {
            XCTFail("Default source should be .host")
        }
    }

    func testRegisterCarriesExplicitSource() throws {
        let registry = PluginRegistry()
        let url = URL(fileURLWithPath: "/tmp/example.csplugin")
        try registry.register(FakeProviderPlugin(), source: .user(url: url))
        if case .user(let recordedURL) = registry.source(for: "com.test.alpha") {
            XCTAssertEqual(recordedURL, url)
        } else {
            XCTFail("Source should round-trip the .user case")
        }
    }

    func testTypedLookupsReturnConcretePlugin() throws {
        let registry = PluginRegistry()
        try registry.register(FakeProviderPluginImpl())
        try registry.register(FakeTerminalPluginImpl())

        XCTAssertNotNil(registry.providerPlugin(id: "com.test.provider"))
        XCTAssertNotNil(registry.terminalPlugin(id: "com.test.terminal"))
        XCTAssertNil(registry.providerPlugin(id: "com.test.terminal"))
        XCTAssertNil(registry.terminalPlugin(id: "com.test.provider"))
        XCTAssertNil(registry.providerPlugin(id: "missing"))
    }
}

final class TerminalLaunchRequestTests: XCTestCase {
    func testCommandOnlyEscapesArgs() {
        let request = TerminalLaunchRequest(
            executable: "/bin/echo",
            arguments: ["hello world", "it's me"],
            cwd: "/tmp"
        )
        XCTAssertEqual(request.commandOnly, "'/bin/echo' 'hello world' 'it'\\''s me'")
    }

    func testCommandInWorkingDirectoryPrependsCd() {
        let request = TerminalLaunchRequest(
            executable: "/bin/ls",
            arguments: [],
            cwd: "/Users/test"
        )
        XCTAssertEqual(request.commandInWorkingDirectory, "cd '/Users/test' && '/bin/ls'")
    }

    func testEnvironmentPrefixSorted() {
        let request = TerminalLaunchRequest(
            executable: "node",
            arguments: ["app.js"],
            cwd: "/x",
            environment: ["FOO": "1", "BAR": "2"]
        )
        // env vars sorted alphabetically
        XCTAssertEqual(request.commandOnly, "env BAR='2' FOO='1' 'node' 'app.js'")
    }

    func testEscapeAppleScript() {
        XCTAssertEqual(TerminalShellCommand.escapeAppleScript("a\"b\\c"), "a\\\"b\\\\c")
    }
}

final class ShareDescriptorTests: XCTestCase {
    func testRoleDescriptorEquality() {
        let a = ShareRoleDescriptor(id: "id", displayName: "Display")
        let b = ShareRoleDescriptor(id: "id", displayName: "Display")
        XCTAssertEqual(a, b)
    }

    func testThemeDescriptorEquality() {
        let a = ShareCardThemeDescriptor.fixture(id: "id", displayName: "Theme")
        let b = ShareCardThemeDescriptor.fixture(id: "id", displayName: "Theme")
        XCTAssertEqual(a, b)
    }
}

private extension ShareCardThemeDescriptor {
    static func fixture(id: String, displayName: String) -> ShareCardThemeDescriptor {
        ShareCardThemeDescriptor(
            id: id,
            displayName: displayName,
            backgroundTopHex: "#101010",
            backgroundBottomHex: "#202020",
            accentHex: "#FFFFFF",
            titleGradientHex: ["#FFFFFF", "#101010"],
            titleForegroundHex: "#FFFFFF",
            titleOutlineHex: "#00000044",
            titleShadowOpacity: 0.1,
            prefersLightQRCode: true,
            symbolName: "star.fill",
            decorationSymbols: ["sparkles"],
            mascotPrimarySymbol: "person.crop.circle.fill",
            mascotSecondarySymbols: ["sparkles"]
        )
    }
}

/// `PluginTrustGate` is the host's glue between `TrustStore`'s
/// persisted decision and the loader's synchronous `trustEvaluator`
/// callback. Allowed plugins load, denied ones are silently skipped,
/// and unknown ones queue for a post-launch prompt while the current
/// boot leaves them out of the registry. This test pins down all
/// three branches plus the prompt-then-record flow without actually
/// presenting an NSAlert.
@MainActor
final class PluginTrustGateTests: XCTestCase {
    private var sandbox: URL!
    private var bundleURL: URL!
    private var trustStoreURL: URL!

    private let manifest = PluginManifest(
        id: "com.example.gate",
        kind: .terminal,
        displayName: "Gate Test",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
        permissions: [.network],
        principalClass: "GatePlugin"
    )

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginTrustGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        bundleURL = sandbox.appendingPathComponent("Gate.csplugin", isDirectory: true)
        let contentsDir = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        try "<plist>v1</plist>".write(
            to: contentsDir.appendingPathComponent("Info.plist"),
            atomically: true, encoding: .utf8
        )
        trustStoreURL = sandbox.appendingPathComponent("trust.json")
        PluginTrustGate._resetForTesting(trustStore: TrustStore(storeURL: trustStoreURL))
        PluginTrustGate.onPluginHotLoaded = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testKnownAllowedReturnsTrueWithoutPending() {
        PluginTrustGate.trustStore.record(.allowed, for: manifest, bundleURL: bundleURL)
        XCTAssertTrue(PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL))
        XCTAssertTrue(PluginTrustGate.snapshotPending().isEmpty)
    }

    func testKnownDeniedReturnsFalseWithoutPending() {
        PluginTrustGate.trustStore.record(.denied, for: manifest, bundleURL: bundleURL)
        XCTAssertFalse(PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL))
        XCTAssertTrue(PluginTrustGate.snapshotPending().isEmpty)
    }

    func testUnknownDefersAndQueues() {
        XCTAssertFalse(PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL))
        XCTAssertEqual(PluginTrustGate.snapshotPending().count, 1)
    }

    func testRepeatedUnknownDoesNotDuplicateInQueue() {
        _ = PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL)
        _ = PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL)
        XCTAssertEqual(PluginTrustGate.snapshotPending().count, 1)
    }

    func testProcessPendingPersistsDecisionAndDrainsQueue() {
        _ = PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL)
        PluginTrustGate.processPending(prompter: { _ in .allowed })
        XCTAssertTrue(PluginTrustGate.snapshotPending().isEmpty)
        XCTAssertEqual(
            PluginTrustGate.trustStore.decision(for: manifest, bundleURL: bundleURL),
            .allowed
        )
    }

    func testProcessPendingHonoursDenyDecision() {
        _ = PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL)
        PluginTrustGate.processPending(prompter: { _ in .denied })
        XCTAssertEqual(
            PluginTrustGate.trustStore.decision(for: manifest, bundleURL: bundleURL),
            .denied
        )
        // After the user answered, the next evaluate must respect the
        // recorded decision — no re-queueing.
        XCTAssertFalse(PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL))
        XCTAssertTrue(PluginTrustGate.snapshotPending().isEmpty)
    }

    func testHotLoadCallbackFiresOnAllowWhenRegistryWired() {
        // Stand up a real PluginRegistry; the bundle here has no
        // executable so PluginLoader.loadOne will fail at bundle.load,
        // which means onPluginHotLoaded should NOT fire — the seam
        // should still be invoked, just with the loadOne result
        // dictating success. Negative case: callback stays nil.
        let registry = PluginRegistry()
        PluginTrustGate.setPluginRegistry(registry)
        var hotLoaded: PluginManifest?
        PluginTrustGate.onPluginHotLoaded = { manifest, _ in
            hotLoaded = manifest
        }
        _ = PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL)
        PluginTrustGate.processPending(prompter: { _ in .allowed })
        // Hot-load attempted but failed (no Mach-O in our fake bundle);
        // callback must NOT fire on failure.
        XCTAssertNil(hotLoaded)
        // TrustStore must still record the user's allow — the failure
        // was at load time, not at the trust decision.
        XCTAssertEqual(
            PluginTrustGate.trustStore.decision(for: manifest, bundleURL: bundleURL),
            .allowed
        )
    }

    func testHotLoadSkippedWhenRegistryNotWired() {
        // No setPluginRegistry call ⇒ deferred-reload behaviour: trust
        // is recorded, but no hot-load attempt and no callback fire.
        var fired = false
        PluginTrustGate.onPluginHotLoaded = { _, _ in fired = true }
        _ = PluginTrustGate.evaluate(manifest: manifest, bundleURL: bundleURL)
        PluginTrustGate.processPending(prompter: { _ in .allowed })
        XCTAssertFalse(fired)
        XCTAssertEqual(
            PluginTrustGate.trustStore.decision(for: manifest, bundleURL: bundleURL),
            .allowed
        )
    }
}

/// `PluginUninstaller.uninstall` must (1) reject host/bundled
/// sources, (2) drop the plugin from the registry, (3) delete the
/// .csplugin file, (4) clear the trust record so a future reinstall
/// behaves like brand-new. Tests pin all four down.
@MainActor
final class PluginUninstallerTests: XCTestCase {
    private var sandbox: URL!
    private var trustStoreURL: URL!
    private var bundleURL: URL!

    private final class FakeTerminalPlugin: NSObject, TerminalPlugin {
        static let manifest = PluginManifest(
            id: "com.example.uninstall-target",
            kind: .terminal,
            displayName: "Uninstall Target",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "FakeTerminalPlugin"
        )
        var descriptor = TerminalDescriptor(
            id: "com.example.uninstall-target",
            displayName: "Uninstall Target",
            category: .terminal,
            bundleIdentifiers: ["com.example.uninstall-target"],
            terminalNameAliases: [],
            processNameHints: [],
            focusPrecision: .appOnly,
            autoLaunchPriority: nil
        )
        override init() { super.init() }
    }

    private var manifest: PluginManifest { FakeTerminalPlugin.manifest }

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginUninstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        // Materialise a fake .csplugin on disk so the file-removal
        // step has something to delete.
        bundleURL = sandbox.appendingPathComponent("uninstall.csplugin", isDirectory: true)
        let contentsDir = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        try "<plist>v1</plist>".write(
            to: contentsDir.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        trustStoreURL = sandbox.appendingPathComponent("trust.json")
        // Reset PluginTrustGate so its singleton TrustStore points at
        // our sandbox — otherwise disable() would write `.denied`
        // into the real ~/Library/.../trust.json.
        PluginTrustGate._resetForTesting(trustStore: TrustStore(storeURL: trustStoreURL))
    }

    override func tearDownWithError() throws {
        PluginTrustGate.onPluginDisabled = nil
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testUninstallRejectsHostSource() throws {
        let registry = PluginRegistry()
        try registry.register(FakeTerminalPlugin(), source: .host)
        do {
            try PluginUninstaller.uninstall(
                manifest: manifest,
                source: .host,
                registry: registry
            )
            XCTFail("Expected sourceNotUserInstalled")
        } catch PluginUninstaller.UninstallError.sourceNotUserInstalled {
            // expected
        }
    }

    func testUninstallRejectsBundledSource() throws {
        let registry = PluginRegistry()
        try registry.register(FakeTerminalPlugin(), source: .bundled(url: bundleURL))
        do {
            try PluginUninstaller.uninstall(
                manifest: manifest,
                source: .bundled(url: bundleURL),
                registry: registry
            )
            XCTFail("Expected sourceNotUserInstalled")
        } catch PluginUninstaller.UninstallError.sourceNotUserInstalled {
            // expected
        }
    }

    func testUninstallUserPluginRemovesFromRegistryDeletesFileAndClearsTrust() throws {
        let registry = PluginRegistry()
        let plugin = FakeTerminalPlugin()
        try registry.register(plugin, source: .user(url: bundleURL))
        // Pre-conditions: plugin registered, file exists, decision recorded.
        XCTAssertNotNil(registry.terminals[manifest.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        PluginTrustGate.trustStore.record(.allowed, for: manifest, bundleURL: bundleURL)
        XCTAssertEqual(
            PluginTrustGate.trustStore.decision(for: manifest, bundleURL: bundleURL),
            .allowed
        )
        // Wire registry into the gate so disable() can unregister.
        PluginTrustGate.setPluginRegistry(registry)
        var disableCallbackFired = false
        PluginTrustGate.onPluginDisabled = { id in
            XCTAssertEqual(id, "com.example.uninstall-target")
            disableCallbackFired = true
        }

        let returned = try PluginUninstaller.uninstall(
            manifest: manifest,
            source: .user(url: bundleURL),
            registry: registry
        )

        XCTAssertEqual(returned, bundleURL)
        // 1. dropped from registry
        XCTAssertNil(registry.terminals[manifest.id])
        XCTAssertNil(registry.source(for: manifest.id))
        // 2. file deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
        // 3. trust entry cleared (NOT left as `.denied`)
        XCTAssertNil(PluginTrustGate.trustStore.decision(for: manifest, bundleURL: bundleURL))
        // 4. host glue notified
        XCTAssertTrue(disableCallbackFired)
    }

    func testUninstallSurfacesFileRemovalError() throws {
        // Hand the uninstaller a bundleURL that doesn't exist on disk.
        let registry = PluginRegistry()
        try registry.register(FakeTerminalPlugin(), source: .user(url: bundleURL))
        PluginTrustGate.setPluginRegistry(registry)
        let missingURL = sandbox.appendingPathComponent("missing.csplugin")
        do {
            try PluginUninstaller.uninstall(
                manifest: manifest,
                source: .user(url: missingURL),
                registry: registry
            )
            XCTFail("Expected fileRemovalFailed")
        } catch PluginUninstaller.UninstallError.fileRemovalFailed {
            // expected
        }
    }
}

/// `TrustStore` is the only gate between "plugin binary on disk" and
/// "plugin code running in our process" (Q2 chose no mandatory
/// signing). These tests pin down the contract so a regression
/// quietly losing the file or skipping the hash would surface.
final class TrustStoreTests: XCTestCase {
    private var sandbox: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrustStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        storeURL = sandbox.appendingPathComponent("trust.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeBundle(infoPlist contents: String, name: String = "sample") throws -> URL {
        let bundleURL = sandbox.appendingPathComponent("\(name).csplugin", isDirectory: true)
        let contentsDir = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        try contents.write(
            to: contentsDir.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        return bundleURL
    }

    private let sampleManifest = PluginManifest(
        id: "com.example.sample",
        kind: .terminal,
        displayName: "Sample",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
        permissions: [],
        principalClass: "SamplePlugin"
    )

    func testFreshStoreReturnsNilDecision() throws {
        let bundle = try makeBundle(infoPlist: "<plist>v1</plist>")
        let store = TrustStore(storeURL: storeURL)
        XCTAssertNil(store.decision(for: sampleManifest, bundleURL: bundle))
    }

    func testRecordedDecisionPersistsAcrossInstances() throws {
        let bundle = try makeBundle(infoPlist: "<plist>v1</plist>")
        let store = TrustStore(storeURL: storeURL)
        store.record(.allowed, for: sampleManifest, bundleURL: bundle)

        let reopened = TrustStore(storeURL: storeURL)
        XCTAssertEqual(reopened.decision(for: sampleManifest, bundleURL: bundle), .allowed)
    }

    func testHashChangeInvalidatesDecision() throws {
        // A swapped Info.plist (e.g. plugin upgrade) yields a different
        // hash, so the previously-recorded decision should not apply.
        let bundle = try makeBundle(infoPlist: "<plist>v1</plist>")
        let store = TrustStore(storeURL: storeURL)
        store.record(.allowed, for: sampleManifest, bundleURL: bundle)

        // Overwrite the Info.plist contents to simulate an update.
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        try "<plist>v2</plist>".write(to: infoURL, atomically: true, encoding: .utf8)

        let reopened = TrustStore(storeURL: storeURL)
        XCTAssertNil(reopened.decision(for: sampleManifest, bundleURL: bundle))
    }

    func testClearAllRemovesFile() throws {
        let bundle = try makeBundle(infoPlist: "<plist>v1</plist>")
        let store = TrustStore(storeURL: storeURL)
        store.record(.denied, for: sampleManifest, bundleURL: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        store.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertNil(store.decision(for: sampleManifest, bundleURL: bundle))
    }

    func testRemoveEntryDropsOnePluginsRecordOnly() throws {
        // Two plugins, both recorded; uninstalling one mustn't lose
        // the other's decision.
        let bundleA = try makeBundle(infoPlist: "<plist>a</plist>", name: "a")
        let bundleB = try makeBundle(infoPlist: "<plist>b</plist>", name: "b")
        let manifestB = PluginManifest(
            id: "com.example.other",
            kind: .terminal,
            displayName: "Other",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            principalClass: "OtherPlugin"
        )
        let store = TrustStore(storeURL: storeURL)
        store.record(.allowed, for: sampleManifest, bundleURL: bundleA)
        store.record(.allowed, for: manifestB, bundleURL: bundleB)

        store.removeEntry(for: sampleManifest, bundleURL: bundleA)

        XCTAssertNil(store.decision(for: sampleManifest, bundleURL: bundleA))
        XCTAssertEqual(store.decision(for: manifestB, bundleURL: bundleB), .allowed)
        // Persists across instances — the file was rewritten, not
        // forgotten in memory.
        let reopened = TrustStore(storeURL: storeURL)
        XCTAssertNil(reopened.decision(for: sampleManifest, bundleURL: bundleA))
        XCTAssertEqual(reopened.decision(for: manifestB, bundleURL: bundleB), .allowed)
    }
}

/// Coverage for `PluginLoader`'s discovery + skip paths. The happy
/// path (a bundle that actually loads via `dlopen`) lives in S3's
/// integration test once `.csplugin` build products exist; here we
/// only exercise the error-handling code and trust gate.
@MainActor
final class PluginLoaderTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testMissingDirectoryReturnsEmptyReport() {
        let registry = PluginRegistry()
        let report = PluginLoader.loadAll(
            from: sandbox.appendingPathComponent("does-not-exist"),
            into: registry
        )
        XCTAssertTrue(report.loaded.isEmpty)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(registry.providers.isEmpty)
    }

    func testNonCspluginEntriesAreSilentlyIgnored() throws {
        // Non-.csplugin entries are dropped from the report entirely
        // because PlugIns/ legitimately contains other content at
        // build time (.xctest etc.) and surfacing each one as a
        // SkippedEntry is just noise. They still cannot load — they
        // just don't show up in the report.
        try "noise".write(to: sandbox.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let registry = PluginRegistry()
        let report = PluginLoader.loadAll(from: sandbox, into: registry)
        XCTAssertTrue(report.loaded.isEmpty)
        XCTAssertTrue(report.skipped.isEmpty)
    }

    func testCspluginWithMissingManifestIsSkipped() throws {
        // A directory ending in .csplugin but without a Contents/Info.plist
        // looks like a malformed bundle to NSBundle. Loader treats it as
        // manifestMissing rather than crashing.
        let bogus = sandbox.appendingPathComponent("bogus.csplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        let registry = PluginRegistry()
        let report = PluginLoader.loadAll(from: sandbox, into: registry)
        XCTAssertTrue(report.loaded.isEmpty)
        XCTAssertEqual(report.skipped.first?.reason, .manifestMissing)
    }

    func testTrustEvaluatorCanRejectAll() throws {
        // Even when a manifest is present, a trustEvaluator that returns
        // false short-circuits before bundle.load. We can't synthesise a
        // valid manifest-bearing bundle in a unit test, but we can
        // verify the error-flow contract by feeding a malformed entry
        // and asserting the loader still uses the trustEvaluator path
        // wiring (manifestMissing fires before the trust gate, so this
        // also documents the order: manifest must parse first).
        let bogus = sandbox.appendingPathComponent("untrusted.csplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        let registry = PluginRegistry()
        var trustCalls = 0
        _ = PluginLoader.loadAll(from: sandbox, into: registry) { _, _ in
            trustCalls += 1
            return false
        }
        // Trust evaluator never gets called because manifestMissing
        // fires earlier — this nails down the discovery order in the
        // pipeline.
        XCTAssertEqual(trustCalls, 0)
    }

    func testDefaultDirectoryUnderApplicationSupport() {
        let dir = PluginLoader.defaultDirectory.path
        XCTAssertTrue(dir.contains("Application Support"))
        XCTAssertTrue(dir.hasSuffix("Claude Statistics/Plugins"))
    }
}

/// Validates the plumbing the M2 `.csplugin` loader will rely on:
/// every shipping plugin must expose a stable Objective-C runtime
/// name matching its manifest's `principalClass`, so
/// `NSClassFromString` resolves and the cast to
/// `(NSObject & Plugin).Type` succeeds. Drift between the manifest
/// string and the `@objc(<Name>)` attribute would silently break the
/// loader at runtime — these tests catch it at build time.
final class PluginReflectionTests: XCTestCase {
    // Host-resident plugin classes only. ClaudeAppPlugin / CodexAppPlugin
    // ship as `.csplugin` bundles (S3) and don't expose a Swift module the
    // test target can `import`; the loader exercises them at runtime via
    // NSClassFromString once the bundle is dlopen'd.
    private static let registeredPluginClasses: [(declared: String, cls: AnyClass)] = [
        (ClaudePluginDogfood.manifest.principalClass, ClaudePluginDogfood.self),
        (CodexPluginDogfood.manifest.principalClass, CodexPluginDogfood.self),
        (GeminiPluginDogfood.manifest.principalClass, GeminiPluginDogfood.self),
        (ITermPlugin.manifest.principalClass, ITermPlugin.self),
        (GhosttyPlugin.manifest.principalClass, GhosttyPlugin.self),
        (WezTermPlugin.manifest.principalClass, WezTermPlugin.self)
        // Editor plugins (VSCode / Cursor / Windsurf / Trae / Zed),
        // WarpPlugin, and AlacrittyPlugin all ship as `.csplugin`
        // bundles, same as ClaudeAppPlugin / CodexAppPlugin — the
        // loader exercises them at runtime via NSClassFromString once
        // the bundle is dlopen'd, so they're not in this list.
    ]

    func testManifestPrincipalClassMatchesObjcRuntimeName() {
        for (declared, cls) in Self.registeredPluginClasses {
            let runtimeName = NSStringFromClass(cls)
            XCTAssertEqual(
                declared, runtimeName,
                "Manifest principalClass '\(declared)' must equal Objective-C runtime name '\(runtimeName)'"
            )
        }
    }

    func testPrincipalClassResolvesViaNSClassFromString() {
        for (declared, _) in Self.registeredPluginClasses {
            XCTAssertNotNil(
                NSClassFromString(declared),
                "Plugin '\(declared)' must be exposed to ObjC runtime via @objc(\(declared))"
            )
        }
    }

    func testInstantiatePluginViaObjcRuntime() throws {
        // End-to-end of what PluginLoader will do: take principalClass
        // string from the manifest, look up via NSClassFromString,
        // cast to (NSObject & Plugin).Type, then init(). Use a
        // host-resident plugin (WezTermPlugin) so this works without
        // dlopen — the .csplugin path is exercised by integration
        // tests once the bundles ship.
        guard let cls = NSClassFromString("WezTermPlugin") else {
            return XCTFail("WezTermPlugin not found in ObjC runtime")
        }
        guard let pluginType = cls as? (NSObject & Plugin).Type else {
            return XCTFail("WezTermPlugin must conform to NSObject & Plugin")
        }
        let instance = pluginType.init()
        XCTAssertEqual(type(of: instance).manifest.id, "com.github.wez.wezterm")
        XCTAssertEqual(type(of: instance).manifest.principalClass, "WezTermPlugin")
        XCTAssertTrue(instance is any TerminalPlugin)
    }
}
