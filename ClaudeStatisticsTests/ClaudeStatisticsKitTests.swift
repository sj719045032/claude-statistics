import XCTest
@testable import Claude_Statistics
@testable import ClaudeStatisticsKit
import ClaudeAppPlugin
import CodexAppPlugin

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
        let a = ShareCardThemeDescriptor(id: "id", displayName: "Theme")
        let b = ShareCardThemeDescriptor(id: "id", displayName: "Theme")
        XCTAssertEqual(a, b)
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
    private static let registeredPluginClasses: [(declared: String, cls: AnyClass)] = [
        (ClaudePluginDogfood.manifest.principalClass, ClaudePluginDogfood.self),
        (CodexPluginDogfood.manifest.principalClass, CodexPluginDogfood.self),
        (GeminiPluginDogfood.manifest.principalClass, GeminiPluginDogfood.self),
        (ITermPlugin.manifest.principalClass, ITermPlugin.self),
        (AppleTerminalPlugin.manifest.principalClass, AppleTerminalPlugin.self),
        (GhosttyPlugin.manifest.principalClass, GhosttyPlugin.self),
        (KittyPlugin.manifest.principalClass, KittyPlugin.self),
        (WezTermPlugin.manifest.principalClass, WezTermPlugin.self),
        (WarpPlugin.manifest.principalClass, WarpPlugin.self),
        (EditorPlugin.manifest.principalClass, EditorPlugin.self),
        (AlacrittyPlugin.manifest.principalClass, AlacrittyPlugin.self),
        (ClaudeAppPlugin.manifest.principalClass, ClaudeAppPlugin.self),
        (CodexAppPlugin.manifest.principalClass, CodexAppPlugin.self)
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
        // cast to (NSObject & Plugin).Type, then init().
        guard let cls = NSClassFromString("ClaudeAppPlugin") else {
            return XCTFail("ClaudeAppPlugin not found in ObjC runtime")
        }
        guard let pluginType = cls as? (NSObject & Plugin).Type else {
            return XCTFail("ClaudeAppPlugin must conform to NSObject & Plugin")
        }
        let instance = pluginType.init()
        XCTAssertEqual(type(of: instance).manifest.id, "com.anthropic.claudefordesktop")
        XCTAssertEqual(type(of: instance).manifest.principalClass, "ClaudeAppPlugin")
        XCTAssertTrue(instance is any TerminalPlugin)
    }
}
