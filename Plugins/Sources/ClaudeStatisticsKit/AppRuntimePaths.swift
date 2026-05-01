import Foundation

/// Shared runtime paths for the host process and any dlopened
/// `.csplugin`. Lives in the SDK so plugins can write hook buffers,
/// socket files, and other per-build state to the same root the
/// host uses (`~/.claude-statistics/` for release, or
/// `~/.claude-statistics-debug/` for debug builds) without taking
/// a host module dependency.
public enum AppRuntimePaths {
    /// Debug builds run out of `~/.claude-statistics-debug/` so they never
    /// share sockets, tokens, hook symlinks, pending buffers, or cached data
    /// with a release install. The whole subtree is per-build, which means
    /// flipping this one line cascades through everything below.
    public static let rootDirectory: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let execPath = ProcessInfo.processInfo.arguments.first ?? ""
        let execName = (execPath as NSString).lastPathComponent

        let isDebug = bundleID.hasSuffix(".debug") ||
                      execPath.contains("/Debug/") ||
                      execPath.hasSuffix("-debug") ||
                      execName.localizedCaseInsensitiveContains("debug")

        let folderName = isDebug ? ".claude-statistics-debug" : ".claude-statistics"
        return (NSHomeDirectory() as NSString).appendingPathComponent(folderName)
    }()
    public static let binDirectory = (rootDirectory as NSString).appendingPathComponent("bin")
    public static let runDirectory = (rootDirectory as NSString).appendingPathComponent("run")

    public static var hookBinaryName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let execPath = ProcessInfo.processInfo.arguments.first ?? ""
        let execName = (execPath as NSString).lastPathComponent
        let isDebug = bundleID.hasSuffix(".debug") ||
                      execPath.contains("/Debug/") ||
                      execPath.hasSuffix("-debug") ||
                      execName.localizedCaseInsensitiveContains("debug")
        return isDebug ? "claude-stats-hook-debug" : "claude-stats-hook"
    }
    /// Disk buffer for hook events that arrived while the app's socket wasn't
    /// listening (errno=ECONNREFUSED on connect). Drained by `AttentionBridge`
    /// at startup so a hook fired during a brief restart window isn't lost.
    public static let pendingDirectory = (rootDirectory as NSString).appendingPathComponent("pending")

    @discardableResult
    public static func ensureRootDirectory() -> String? {
        ensureDirectory(rootDirectory, permissions: 0o700)
    }

    @discardableResult
    public static func ensureBinDirectory() -> String? {
        guard ensureRootDirectory() != nil else { return nil }
        return ensureDirectory(binDirectory, permissions: 0o700)
    }

    @discardableResult
    public static func ensureRunDirectory() -> String? {
        guard ensureRootDirectory() != nil else { return nil }
        return ensureDirectory(runDirectory, permissions: 0o700)
    }

    @discardableResult
    public static func ensurePendingDirectory() -> String? {
        guard ensureRootDirectory() != nil else { return nil }
        return ensureDirectory(pendingDirectory, permissions: 0o700)
    }

    public static func runFile(named fileName: String) -> String? {
        guard let directory = ensureRunDirectory() else { return nil }
        return (directory as NSString).appendingPathComponent(fileName)
    }

    public static func uniqueRunFile(prefix: String, extension fileExtension: String) -> String? {
        let name = "\(prefix)-\(UUID().uuidString).\(fileExtension)"
        return runFile(named: name)
    }

    @discardableResult
    private static func ensureDirectory(_ path: String, permissions: Int) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            return path
        } catch {
            DiagnosticLogger.shared.warning("Runtime directory unavailable path=\(path) error=\(error.localizedDescription)")
            return nil
        }
    }
}
