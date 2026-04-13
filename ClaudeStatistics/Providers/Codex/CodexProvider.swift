import Foundation

final class CodexProvider: SessionProvider, @unchecked Sendable {
    static let shared = CodexProvider()

    let kind: ProviderKind = .codex
    let displayName = ProviderKind.codex.displayName
    let capabilities = ProviderCapabilities.codex
    let usageSource: (any ProviderUsageSource)? = CodexUsageService.shared
    let configDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")

    // credentialStatus: nil — Codex profile is decoded locally, no explicit credential check needed
    var statusLineInstaller: (any StatusLineInstalling)? { CodexStatusLineAdapter() }

    private init() {}

    func fetchProfile() async -> UserProfile? {
        CodexUsageService.shared.decodeProfile()
    }

    func resolvedProjectPath(for session: Session) -> String {
        session.cwd ?? session.projectPath
    }

    func scanSessions() -> [Session] {
        CodexSessionScanner.shared.scanSessions()
    }

    func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)? {
        nil
    }

    func parseQuickStats(at path: String) -> SessionQuickStats {
        CodexTranscriptParser.shared.parseSessionQuick(at: path)
    }

    func parseSession(at path: String) -> SessionStats {
        CodexTranscriptParser.shared.parseSession(at: path)
    }

    func parseMessages(at path: String) -> [TranscriptDisplayMessage] {
        CodexTranscriptParser.shared.parseMessages(at: path)
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        CodexTranscriptParser.shared.parseTrendData(from: filePath, granularity: granularity)
    }

    func openNewSession(_ session: Session) {
        TerminalLauncher.launch(executable: "codex", arguments: [], cwd: resolvedProjectPath(for: session))
    }

    func resumeSession(_ session: Session) {
        TerminalLauncher.launch(executable: "codex", arguments: ["resume", session.id], cwd: resolvedProjectPath(for: session))
    }

    func openNewSession(inDirectory path: String) {
        TerminalLauncher.launch(executable: "codex", arguments: [], cwd: path)
    }
}

// MARK: - StatusLine adapter

struct CodexStatusLineAdapter: StatusLineInstalling {
    var isInstalled: Bool { CodexStatusLineInstaller.isInstalled }
    var titleLocalizationKey: String { "statusLine.codex.title" }
    var descriptionLocalizationKey: String { "statusLine.codex.description" }
    func install() throws { try CodexStatusLineInstaller.install() }
}
