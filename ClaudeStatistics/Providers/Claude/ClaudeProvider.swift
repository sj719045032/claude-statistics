import Foundation

final class ClaudeProvider: SessionProvider, @unchecked Sendable {
    static let shared = ClaudeProvider()

    let kind: ProviderKind = .claude
    let displayName = ProviderKind.claude.displayName
    let capabilities = ProviderCapabilities.claude
    let usageSource: (any ProviderUsageSource)? = UsageAPIService.shared
    let configDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")

    var credentialStatus: Bool? { CredentialService.shared.getAccessToken() != nil }
    var statusLineInstaller: (any StatusLineInstalling)? { ClaudeStatusLineAdapter() }

    private init() {}

    func fetchProfile() async -> UserProfile? {
        do {
            return try await UsageAPIService.shared.fetchProfile()
        } catch {
            let refreshed = await UsageAPIService.shared.refreshToken()
            if refreshed { return try? await UsageAPIService.shared.fetchProfile() }
            return nil
        }
    }

    func resolvedProjectPath(for session: Session) -> String {
        session.cwd ?? session.projectPath
    }

    func scanSessions() -> [Session] {
        SessionScanner.shared.scanSessions()
    }

    func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)? {
        let projectsDir = (CredentialService.shared.claudeConfigDir() as NSString).appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projectsDir) else { return nil }
        return FSEventsWatcher(path: projectsDir, debounceSeconds: 2.0, onChange: onChange)
    }

    func parseQuickStats(at path: String) -> SessionQuickStats {
        TranscriptParser.shared.parseSessionQuick(at: path)
    }

    func parseSession(at path: String) -> SessionStats {
        TranscriptParser.shared.parseSession(at: path)
    }

    func parseMessages(at path: String) -> [TranscriptDisplayMessage] {
        TranscriptParser.shared.parseMessages(at: path)
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        TranscriptParser.shared.parseTrendData(from: filePath, granularity: granularity)
    }

    func openNewSession(_ session: Session) {
        TerminalLauncher.launch(executable: "claude", arguments: [], cwd: resolvedProjectPath(for: session))
    }

    func resumeSession(_ session: Session) {
        TerminalLauncher.launch(executable: "claude", arguments: ["--resume", session.id], cwd: resolvedProjectPath(for: session))
    }

    func openNewSession(inDirectory path: String) {
        TerminalLauncher.launch(executable: "claude", arguments: [], cwd: path)
    }
}

// MARK: - StatusLine adapter

struct ClaudeStatusLineAdapter: StatusLineInstalling {
    var isInstalled: Bool { StatusLineInstaller.isInstalled }
    var hasRestoreOption: Bool { StatusLineInstaller.hasBackup }
    var titleLocalizationKey: String { "statusLine.title" }
    var descriptionLocalizationKey: String { "statusLine.description" }
    func install() throws { try StatusLineInstaller.install() }
    func restore() throws { try StatusLineInstaller.restore() }
}
