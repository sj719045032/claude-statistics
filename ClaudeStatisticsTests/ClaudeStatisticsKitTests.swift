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
        let a = ShareCardThemeDescriptor(id: "id", displayName: "Theme")
        let b = ShareCardThemeDescriptor(id: "id", displayName: "Theme")
        XCTAssertEqual(a, b)
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
        (AppleTerminalPlugin.manifest.principalClass, AppleTerminalPlugin.self),
        (GhosttyPlugin.manifest.principalClass, GhosttyPlugin.self),
        (KittyPlugin.manifest.principalClass, KittyPlugin.self),
        (WezTermPlugin.manifest.principalClass, WezTermPlugin.self),
        (WarpPlugin.manifest.principalClass, WarpPlugin.self),
        (EditorPlugin.manifest.principalClass, EditorPlugin.self),
        (AlacrittyPlugin.manifest.principalClass, AlacrittyPlugin.self)
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
        // host-resident plugin (KittyPlugin) so this works without
        // dlopen — the .csplugin path is exercised by integration
        // tests once the bundles ship.
        guard let cls = NSClassFromString("KittyPlugin") else {
            return XCTFail("KittyPlugin not found in ObjC runtime")
        }
        guard let pluginType = cls as? (NSObject & Plugin).Type else {
            return XCTFail("KittyPlugin must conform to NSObject & Plugin")
        }
        let instance = pluginType.init()
        XCTAssertEqual(type(of: instance).manifest.id, "net.kovidgoyal.kitty")
        XCTAssertEqual(type(of: instance).manifest.principalClass, "KittyPlugin")
        XCTAssertTrue(instance is any TerminalPlugin)
    }
}
