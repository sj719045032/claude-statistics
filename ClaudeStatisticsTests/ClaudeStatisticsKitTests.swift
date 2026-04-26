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
}

@MainActor
final class PluginRegistryTests: XCTestCase {
    private final class FakeProviderPlugin: Plugin {
        static let manifest = PluginManifest(
            id: "com.test.alpha",
            kind: .provider,
            displayName: "Alpha",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "FakeProviderPlugin"
        )
        init() {}
    }

    private final class FakeTerminalPlugin: Plugin {
        static let manifest = PluginManifest(
            id: "com.test.beta",
            kind: .terminal,
            displayName: "Beta",
            version: SemVer(major: 0, minor: 9, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [.accessibility],
            principalClass: "FakeTerminalPlugin"
        )
        init() {}
    }

    private final class FakeBothPlugin: Plugin {
        static let manifest = PluginManifest(
            id: "com.test.combo",
            kind: .both,
            displayName: "Combo",
            version: SemVer(major: 1, minor: 0, patch: 0),
            minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
            permissions: [],
            principalClass: "FakeBothPlugin"
        )
        init() {}
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
}
