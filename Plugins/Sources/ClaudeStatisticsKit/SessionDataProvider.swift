import Foundation

/// Plugin contribution that scans, watches and parses session files for one
/// provider's CLI. The host invokes these methods on a strict cadence:
/// `scanSessions` on app start + on file-watcher debounce, then `parseSession`
/// + `parseQuickStats` for individual sessions on demand.
///
/// Stage-3 migration: this protocol used to expose `var kind: ProviderKind`
/// for identity. The descriptor-id rename to `providerId: String` is what
/// makes the protocol portable across host + third-party plugins.
public protocol SessionDataProvider: Sendable {
    /// `ProviderDescriptor.id` of the plugin owning this data provider.
    /// Builtins use `"claude"` / `"codex"` / `"gemini"`; third-party plugins
    /// use their reverse-DNS id (e.g. `"com.example.aider"`).
    var providerId: String { get }

    var capabilities: ProviderCapabilities { get }

    /// The provider's config directory path (e.g. `~/.claude`). Used to
    /// detect installation.
    var configDirectory: String { get }

    /// Whether the provider needs a full rescan whenever any watched file
    /// changes. False for providers with stable per-session file naming.
    var alwaysRescanOnFileChanges: Bool { get }

    func resolvedProjectPath(for session: Session) -> String
    func scanSessions() -> [Session]
    func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)?
    func changedSessionIds(for changedPaths: Set<String>) -> Set<String>
    func shouldRescanSessions(for changedPaths: Set<String>) -> Bool

    func parseQuickStats(at path: String) -> SessionQuickStats
    func parseSession(at path: String) -> SessionStats
    func parseMessages(at path: String) -> [TranscriptDisplayMessage]
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage]
    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint]
}

extension SessionDataProvider {
    public var alwaysRescanOnFileChanges: Bool { false }

    public func changedSessionIds(for changedPaths: Set<String>) -> Set<String> {
        var changedIds: Set<String> = []
        for path in changedPaths {
            let fileName = (path as NSString).lastPathComponent
            guard fileName.hasSuffix(".jsonl") else { continue }
            changedIds.insert((fileName as NSString).deletingPathExtension)
        }
        return changedIds
    }

    public func shouldRescanSessions(for changedPaths: Set<String>) -> Bool {
        alwaysRescanOnFileChanges
    }

    /// Returns `true` when the provider's config directory exists.
    /// More reliable than PATH-based detection in sandboxed/Dock-launched
    /// macOS apps.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: configDirectory)
    }
}
