import CryptoKit
import Foundation

/// Downloads a `.csplugin.zip` from a marketplace entry, verifies its
/// SHA-256, unzips into a sandbox, validates the resulting bundle's
/// manifest matches the entry, then atomically moves the bundle to
/// the user plugin directory and hands off to `PluginLoader.loadOne`.
///
/// The installer **does not** present any UI; it returns a typed
/// result (`InstallReport`) the host's `PluginDiscoverView` renders
/// into a row badge ("Installed v1.2.3" / red error toast / etc.).
///
/// `TrustStore` is updated to `.allowed` for the manifest+url before
/// the loader runs, because catalog-driven installs are explicit user
/// intent — we don't fire the M2 "first-launch trust prompt" again.
///
/// Heavy operations (download, hash, unzip) run on a background queue
/// via `Task.detached`; the registry mutation happens on the main
/// actor. See `docs/PLUGIN_MARKETPLACE.md` §4.2 for the full flow.
public enum PluginInstaller {
    public enum InstallError: Error, Equatable {
        case downloadFailed(String)
        case sha256Mismatch(expected: String, actual: String)
        case unzipFailed(String)
        case missingPluginBundle
        case bundleLoadFailed(path: String)
        case manifestKeyMissing(path: String)
        case manifestIDMismatch(expected: String, actual: String)
        case incompatibleAPIVersion(required: SemVer, host: SemVer)
        case moveFailed(String)
        case loadFailed(PluginLoader.SkipReason)
    }

    public struct InstallReport: Sendable {
        public let manifest: PluginManifest
        public let bundleURL: URL
    }

    /// Hooks the actual file-moving destination. Defaults (the host
    /// supplies `{ PluginLoader.defaultDirectory }` at the call
    /// site since `defaultDirectory` is `@MainActor`); tests
    /// override with a sandbox URL.
    public typealias DestinationProvider = @Sendable () -> URL

    /// URL data fetcher used for the .zip download. Tests inject a
    /// stub returning a precomputed zip to keep the suite hermetic.
    public typealias DataLoader = @Sendable (URL) async throws -> Data

    /// Default downloader uses URLSession.
    public static let urlSessionLoader: DataLoader = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.downloadFailed("HTTP \(http.statusCode)")
        }
        return data
    }

    /// Run the full install pipeline for a single catalog entry.
    /// Caller supplies `destinationProvider` — typically
    /// `{ PluginLoader.defaultDirectory }` from a `@MainActor`
    /// context. Tests pass a sandbox URL.
    @MainActor
    public static func install(
        entry: PluginCatalogEntry,
        into registry: PluginRegistry,
        trustStore: TrustStore = TrustStore(),
        destination destinationProvider: @escaping DestinationProvider,
        loader: @escaping DataLoader = PluginInstaller.urlSessionLoader
    ) async throws -> InstallReport {
        let stagedBundle = try await stageBundle(
            entry: entry,
            loader: loader
        )
        defer {
            // Clean up the staging directory regardless of outcome.
            try? FileManager.default.removeItem(at: stagedBundle.stagingRoot)
        }
        let destinationDir = destinationProvider()
        let installedURL = try moveIntoDestination(
            stagedBundle: stagedBundle.bundleURL,
            destinationDir: destinationDir
        )
        // Pre-trust before loading so PluginTrustGate.evaluate
        // doesn't queue this for a prompt — catalog install is
        // explicit user intent.
        trustStore.record(.allowed, for: stagedBundle.manifest, bundleURL: installedURL)
        let loadResult = PluginLoader.loadOne(
            at: installedURL,
            into: registry,
            source: .user(url: installedURL)
        )
        switch loadResult {
        case .success(let manifest):
            return InstallReport(manifest: manifest, bundleURL: installedURL)
        case .failure(let reason):
            throw InstallError.loadFailed(reason)
        }
    }

    // MARK: - Pipeline steps

    public struct StagedBundle: Sendable {
        public let stagingRoot: URL
        public let bundleURL: URL
        public let manifest: PluginManifest
    }

    /// Steps 1–5 from §4.2: download → sha256 → unzip → find bundle
    /// → validate manifest matches the entry. Returns a bundle URL
    /// inside a temp directory the caller still has to move into
    /// place.
    public nonisolated static func stageBundle(
        entry: PluginCatalogEntry,
        loader: @escaping DataLoader
    ) async throws -> StagedBundle {
        // 1. Download
        let zipData: Data
        do {
            zipData = try await loader(entry.downloadURL)
        } catch let installError as InstallError {
            throw installError
        } catch {
            throw InstallError.downloadFailed(String(describing: error))
        }

        // 2. SHA-256 verify
        let actualHash = sha256(of: zipData)
        guard actualHash.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw InstallError.sha256Mismatch(expected: entry.sha256, actual: actualHash)
        }

        // 3. Unzip into a temp staging dir
        let stagingRoot = try makeStagingDirectory()
        let zipURL = stagingRoot.appendingPathComponent("payload.zip")
        try zipData.write(to: zipURL)
        try unzip(zipURL: zipURL, into: stagingRoot)

        let stagingListing = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?
            .sorted().joined(separator: ", ") ?? "<unreadable>"
        DiagnosticLogger.shared.info(
            "PluginInstaller: unzip done; stagingRoot=\(stagingRoot.path); zipBytes=\(zipData.count); contents=[\(stagingListing)]"
        )

        // 4. Locate the .csplugin bundle in the unzipped contents.
        let bundleURL = try findCspluginBundle(in: stagingRoot)
        let bundleContents = (try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path))?
            .sorted().joined(separator: ", ") ?? "<unreadable>"
        let contentsDir = bundleURL.appendingPathComponent("Contents")
        let contentsListing = (try? FileManager.default.contentsOfDirectory(atPath: contentsDir.path))?
            .sorted().joined(separator: ", ") ?? "<unreadable>"
        DiagnosticLogger.shared.info(
            "PluginInstaller: bundleURL=\(bundleURL.path); bundle entries=[\(bundleContents)]; Contents=[\(contentsListing)]"
        )

        // 5. Validate manifest matches entry id + host API.
        // Try Bundle(url:) first; fall back to direct Info.plist read
        // when Bundle returns nil. Observed on macOS: a freshly-unzipped
        // `.csplugin` in `NSTemporaryDirectory()` sometimes refuses to
        // load via Bundle API even though the bundle layout is valid
        // (suspected: bundle cache keyed by CFBundleIdentifier, or
        // dyld-style sanity checks on the embedded mach-O — neither
        // matters at the manifest-validation stage).
        let manifest = try readManifest(bundleURL: bundleURL)
        guard manifest.id == entry.id else {
            throw InstallError.manifestIDMismatch(expected: entry.id, actual: manifest.id)
        }
        guard manifest.minHostAPIVersion <= SDKInfo.apiVersion else {
            throw InstallError.incompatibleAPIVersion(
                required: manifest.minHostAPIVersion,
                host: SDKInfo.apiVersion
            )
        }

        return StagedBundle(
            stagingRoot: stagingRoot,
            bundleURL: bundleURL,
            manifest: manifest
        )
    }

    /// Step 6: atomic move into the user plugin dir, replacing any
    /// existing same-id bundle (so updating a plugin overwrites the
    /// older one).
    @MainActor
    private static func moveIntoDestination(
        stagedBundle: URL,
        destinationDir: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationDir,
            withIntermediateDirectories: true
        )
        let destination = destinationDir
            .appendingPathComponent(stagedBundle.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: stagedBundle, to: destination)
        } catch {
            throw InstallError.moveFailed(String(describing: error))
        }
        return destination
    }

    // MARK: - Helpers

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func makeStagingDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ClaudeStatistics-PluginStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func unzip(zipURL: URL, into destination: URL) throws {
        // /usr/bin/unzip is universal on macOS and avoids pulling in
        // Foundation's NSFileManager.unzipItem (which doesn't exist).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipURL.path, "-d", destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw InstallError.unzipFailed(String(describing: error))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errMessage = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unzip exit \(process.terminationStatus)"
            throw InstallError.unzipFailed(errMessage)
        }
    }

    /// Decode the plugin manifest from the unzipped bundle. Tries
    /// `Bundle(url:)` → `bundle.object(forInfoDictionaryKey:)` first;
    /// on any failure falls back to reading `Contents/Info.plist`
    /// directly through `PropertyListSerialization`. The fallback is
    /// what saves us on staging dirs where `Bundle(url:)` returns
    /// nil for non-app/non-framework wrappers.
    nonisolated static func readManifest(bundleURL: URL) throws -> PluginManifest {
        if let bundle = Bundle(url: bundleURL),
           let manifest = PluginManifest(bundle: bundle) {
            return manifest
        }

        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL) else {
            DiagnosticLogger.shared.error(
                "PluginInstaller.readManifest: Info.plist not found at \(infoURL.path)"
            )
            throw InstallError.bundleLoadFailed(path: bundleURL.path)
        }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            DiagnosticLogger.shared.error(
                "PluginInstaller.readManifest: Info.plist parse failed at \(infoURL.path): \(error.localizedDescription)"
            )
            throw InstallError.bundleLoadFailed(path: bundleURL.path)
        }

        guard let dict = plist as? [String: Any] else {
            DiagnosticLogger.shared.error(
                "PluginInstaller.readManifest: plist top-level is \(type(of: plist)) not [String: Any] at \(infoURL.path)"
            )
            throw InstallError.bundleLoadFailed(path: bundleURL.path)
        }
        guard let manifestRaw = dict[PluginManifest.infoDictionaryKey] else {
            let keys = dict.keys.sorted().joined(separator: ", ")
            let dataSize = data.count
            // Sneak the diagnostic into the error path so it surfaces
            // in the UI toast, not just in DiagnosticLogger — every
            // path the toast can reach helps narrow `Bundle(url:)`
            // refusal cases.
            DiagnosticLogger.shared.error(
                "PluginInstaller.readManifest: \(PluginManifest.infoDictionaryKey) missing at \(infoURL.path); plist size=\(dataSize) bytes; top-level keys=[\(keys)]"
            )
            throw InstallError.manifestKeyMissing(path: "\(bundleURL.path) — keys=[\(keys)] size=\(dataSize)")
        }

        let manifestData: Data
        do {
            manifestData = try PropertyListSerialization.data(
                fromPropertyList: manifestRaw, format: .binary, options: 0
            )
        } catch {
            DiagnosticLogger.shared.error(
                "PluginInstaller.readManifest: serialize manifestRaw failed at \(infoURL.path): \(error)"
            )
            throw InstallError.manifestKeyMissing(path: "\(bundleURL.path) — serialize: \(error.localizedDescription)")
        }

        let manifest: PluginManifest
        do {
            manifest = try PluginManifest(plistData: manifestData)
        } catch {
            let keys: String
            if let dict = manifestRaw as? [String: Any] {
                keys = dict.keys.sorted().joined(separator: ", ")
            } else {
                keys = "<not a dict: \(type(of: manifestRaw))>"
            }
            DiagnosticLogger.shared.error(
                "PluginInstaller.readManifest: PluginManifest decode error at \(infoURL.path); keys=[\(keys)]; error=\(error)"
            )
            throw InstallError.manifestKeyMissing(path: "\(bundleURL.path) — decode: \(error.localizedDescription)")
        }

        DiagnosticLogger.shared.warning(
            "PluginInstaller.readManifest: Bundle(url:) returned nil at \(bundleURL.path); fell back to direct Info.plist read"
        )
        return manifest
    }

    nonisolated static func findCspluginBundle(in directory: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        // Most zips wrap a single `<name>.csplugin/` at top level. If
        // the archive nested it under another directory (e.g.
        // `MyPlugin-1.0.0/MyPlugin.csplugin`), descend one level.
        for url in entries where url.pathExtension == "csplugin" {
            return url
        }
        for url in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let nested = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for inner in nested where inner.pathExtension == "csplugin" {
                return inner
            }
        }
        throw InstallError.missingPluginBundle
    }
}
