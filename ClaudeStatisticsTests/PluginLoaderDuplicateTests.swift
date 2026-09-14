import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// A bundle whose id already fills its registry bucket must be refused before
/// it is dlopened: a loaded image cannot be unloaded, and two images of one
/// Swift module in the same process leave class lookup ambiguous.
@MainActor
final class PluginLoaderDuplicateTests: XCTestCase {
    private final class Occupant: NSObject, Plugin {
        static let manifest = PluginManifest(
            id: "com.test.duplicate",
            kind: .provider,
            displayName: "Occupant",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "Occupant"
        )
        override init() { super.init() }
    }

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("LoaderDuplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    /// A `.csplugin` with a valid manifest and no executable: if the loader
    /// ever reaches `bundle.load()`, it reports `.bundleLoadFailed`.
    private func makeBundle(id: String, kind: PluginKind) throws -> URL {
        let manifest = PluginManifest(
            id: id, kind: kind, displayName: "Fixture",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [], principalClass: "FixturePlugin"
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "\(id).\(kind.rawValue)",
            "CFBundleName": "Fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "BNDL",
            "NSPrincipalClass": "FixturePlugin",
            PluginManifest.infoDictionaryKey: try manifest.encodedAsPlistDictionary(),
        ]
        let bundle = sandbox.appendingPathComponent("Fixture-\(kind.rawValue).csplugin", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    func testADuplicateIsRefusedBeforeItsBundleIsLoaded() throws {
        let registry = PluginRegistry()
        try registry.register(Occupant())
        let result = PluginLoader.loadOne(at: try makeBundle(id: Occupant.manifest.id, kind: .provider), into: registry)
        guard case .failure(.duplicateId(let id, let bucket)) = result else {
            return XCTFail("expected duplicateId before dlopen, got \(result)")
        }
        XCTAssertEqual(id, Occupant.manifest.id)
        XCTAssertEqual(bucket, "provider")
    }

    /// Codex's provider and its terminal adapter share one id in different
    /// buckets; that pairing must still reach the loader.
    func testTheSameIdInAnotherBucketStillLoads() throws {
        let registry = PluginRegistry()
        try registry.register(Occupant())
        let result = PluginLoader.loadOne(at: try makeBundle(id: Occupant.manifest.id, kind: .terminal), into: registry)
        guard case .failure(.bundleLoadFailed) = result else {
            return XCTFail("expected the loader to reach dlopen (no executable), got \(result)")
        }
    }
}
