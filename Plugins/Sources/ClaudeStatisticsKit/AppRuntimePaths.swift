import Foundation

/// Shared runtime paths for the host process and any dlopened
/// `.csplugin`. Lives in the SDK so plugins can write hook buffers,
/// socket files, and other per-build state to the same root the
/// host uses (`~/.claude-statistics/` for release, or
/// `~/.claude-statistics-debug/` for debug builds) without taking
/// a host module dependency.
public enum AppRuntimePaths {
    public enum RuntimeChannel: String, Sendable {
        case release
        case debug

        var rootFolderName: String {
            switch self {
            case .release: return ".claude-statistics"
            case .debug: return ".claude-statistics-debug"
            }
        }

        var hookBinaryName: String {
            switch self {
            case .release: return "claude-stats-hook"
            case .debug: return "claude-stats-hook-debug"
            }
        }
    }

    public static let channel: RuntimeChannel = {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let execPath = ProcessInfo.processInfo.arguments.first ?? ""
        let execName = (execPath as NSString).lastPathComponent

        let isDebug = bundleID.hasSuffix(".debug") ||
                      execPath.contains("/Debug/") ||
                      execPath.hasSuffix("-debug") ||
                      execName.localizedCaseInsensitiveContains("debug")
        return isDebug ? .debug : .release
    }()

    public static var isDebug: Bool { channel == .debug }

    /// Debug builds run out of `~/.claude-statistics-debug/` so they never
    /// share sockets, tokens, hook symlinks, pending buffers, or cached data
    /// with a release install. The whole subtree is per-build, which means
    /// flipping this one line cascades through everything below.
    public static let rootDirectory: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(channel.rootFolderName)
    }()
    public static let binDirectory = (rootDirectory as NSString).appendingPathComponent("bin")
    public static let runDirectory = (rootDirectory as NSString).appendingPathComponent("run")

    public static var hookBinaryName: String {
        channel.hookBinaryName
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

    // MARK: - Installed-terminal bundle list

    /// Disk file the host overwrites after every PluginRegistry
    /// mutation, listing the bundle ids of every currently-installed
    /// terminal plugin (one per line). HookCLI reads this at startup
    /// to short-circuit when the hook fires from a host whose plugin
    /// isn't installed — avoids round-tripping a hook event through
    /// the socket only for AttentionBridge to drop it. The host-side
    /// drop in AttentionBridge stays in place as defense-in-depth.
    public static let installedTerminalBundlesFile = (rootDirectory as NSString).appendingPathComponent("installed-terminal-bundles.txt")

    /// Read the bundle id allow-list. Returns nil when the file is
    /// missing or unreadable so callers can fall through to the
    /// existing path (host-side AttentionBridge claim filter). File
    /// absence MUST NEVER cause a false drop — only an explicit list
    /// where the bundle id is missing does.
    public static func loadInstalledTerminalBundles() -> Set<String>? {
        guard let raw = try? String(contentsOfFile: installedTerminalBundlesFile, encoding: .utf8) else {
            return nil
        }
        let ids = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(ids)
    }

    /// Atomically replace the bundle id allow-list. Sorted for stable
    /// disk content so identical plugin sets don't churn the file's
    /// mtime across unrelated lifecycle pings.
    @discardableResult
    public static func writeInstalledTerminalBundles(_ ids: Set<String>) -> Bool {
        guard ensureRootDirectory() != nil else { return false }
        let body = ids.sorted().joined(separator: "\n") + "\n"
        do {
            try body.write(toFile: installedTerminalBundlesFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            DiagnosticLogger.shared.warning(
                "Installed-terminal-bundles write failed path=\(installedTerminalBundlesFile) error=\(error.localizedDescription)"
            )
            return false
        }
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
