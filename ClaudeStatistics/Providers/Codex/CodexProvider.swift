import Foundation
import ClaudeStatisticsKit

final class CodexProvider: SessionProvider, @unchecked Sendable {
    static let shared = CodexProvider()

    let kind: ProviderKind = .codex
    var providerId: String { kind.rawValue }
    let displayName = ProviderKind.codex.displayName
    let capabilities = ProviderCapabilities.codex
    let usageSource: (any ProviderUsageSource)? = CodexUsageService.shared
    let configDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    let builtinPricingModels = CodexPricingCatalog.builtinModels

    // credentialStatus: nil — Codex profile is decoded locally, no explicit credential check needed
    var statusLineInstaller: (any StatusLineInstalling)? { CodexStatusLineAdapter() }
    var notchHookInstaller: (any HookInstalling)? { CodexHookInstaller() }
    // Current local Codex traces still mostly show the core 6 events, but we
    // register the broader lifecycle set so waiting/failed paths can surface
    // automatically as the runtime exposes them.
    var supportedNotchEvents: Set<NotchEventKind> { [.permission, .waitingInput, .taskDone, .taskFailed] }
    var pricingFetcher: (any ProviderPricingFetching)? { CodexPricingFetchService.shared }
    var pricingSourceLocalizationKey: String? { "pricing.source.codex" }
    var pricingSourceURL: URL? { URL(string: "https://developers.openai.com/api/docs/pricing") }
    var pricingUpdatedLocalizationKey: String? { "pricing.updated.codex" }
    var credentialHintLocalizationKey: String? { "settings.credentialHint.codex" }

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
        let rootPath = CodexSessionScanner.codexRootPath
        guard FileManager.default.fileExists(atPath: rootPath) else { return nil }
        return FSEventsWatcher(
            path: rootPath,
            debounceSeconds: 2.0,
            fileFilter: { path in
                if path.contains("/sessions/") && path.hasSuffix(".jsonl") {
                    return true
                }
                let fileName = (path as NSString).lastPathComponent
                return fileName == "state_5.sqlite" ||
                    fileName == "state_5.sqlite-wal" ||
                    fileName == "state_5.sqlite-shm"
            },
            onChange: onChange
        )
    }

    func changedSessionIds(for changedPaths: Set<String>) -> Set<String> {
        Set(changedPaths.compactMap { path in
            guard path.contains("/sessions/") else { return nil }
            return CodexSessionScanner.sessionId(forRolloutPath: path)
        })
    }

    func shouldRescanSessions(for changedPaths: Set<String>) -> Bool {
        changedPaths.contains { path in
            let fileName = (path as NSString).lastPathComponent
            return fileName == "state_5.sqlite" ||
                fileName == "state_5.sqlite-wal" ||
                fileName == "state_5.sqlite-shm"
        }
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

    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        CodexTranscriptParser.shared.parseSearchIndexMessages(at: path)
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        CodexTranscriptParser.shared.parseTrendData(from: filePath, granularity: granularity)
    }

    func openNewSession(_ session: Session) {
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "codex",
                arguments: [],
                cwd: resolvedProjectPath(for: session)
            )
        )
    }

    func resumeSession(_ session: Session) {
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "codex",
                arguments: ["resume", session.externalID],
                cwd: resolvedProjectPath(for: session)
            )
        )
    }

    func resumeCommand(for session: Session) -> String {
        TerminalLaunchRequest(
            executable: "codex",
            arguments: ["resume", session.externalID],
            cwd: resolvedProjectPath(for: session)
        ).commandInWorkingDirectory
    }

    func openNewSession(inDirectory path: String) {
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "codex",
                arguments: [],
                cwd: path
            )
        )
    }
}

// MARK: - Tool name canonicalization

/// Maps Codex's raw tool names (`apply_patch`, `exec_command`, …) onto the
/// shared canonical vocabulary (`edit`, `bash`, …). Input is expected to be
/// the lower-cased/underscore-normalized form that `ProviderKind
/// .canonicalToolName(_:)` produces; returns `nil` when no alias applies so
/// the caller can keep the original name.
enum CodexToolNames {
    static func canonical(_ normalized: String) -> String? {
        switch normalized {
        case "exec_command", "write_stdin", "local_shell":
            return "bash"
        case "apply_patch":
            return "edit"
        case "read_mcp_resource":
            return "read"
        default:
            return nil
        }
    }
}

// MARK: - StatusLine adapter

struct CodexStatusLineAdapter: StatusLineInstalling {
    var isInstalled: Bool { CodexStatusLineInstaller.isInstalled }
    var hasRestoreOption: Bool { CodexStatusLineInstaller.hasBackup }
    var titleLocalizationKey: String { "statusLine.codex.title" }
    var descriptionLocalizationKey: String { "statusLine.codex.description" }
    var legendSections: [StatusLineLegendSection] {
        [
            StatusLineLegendSection(
                titleLocalizationKey: "statusLine.legend.section.codex",
                items: [
                    StatusLineLegendItem(example: "5h 42%", descriptionLocalizationKey: "statusLine.legend.codex.fiveHour"),
                    StatusLineLegendItem(example: "7d 36%", descriptionLocalizationKey: "statusLine.legend.codex.sevenDay"),
                    StatusLineLegendItem(example: "ctx 68%", descriptionLocalizationKey: "statusLine.legend.codex.context"),
                    StatusLineLegendItem(example: "↑ 128k  ↓ 24k", descriptionLocalizationKey: "statusLine.legend.codex.tokens")
                ]
            )
        ]
    }
    func install() throws { try CodexStatusLineInstaller.install() }
    func restore() throws { try CodexStatusLineInstaller.restore() }
}

enum CodexPricingCatalog {
    // Source: OpenAI pricing pages verified on 2026-04-14
    static let builtinModels: [String: ModelPricing.Pricing] = [
        "gpt-5":              ModelPricing.Pricing(input: 1.25, output: 10.0, cacheWrite5m: 1.25, cacheWrite1h: 1.25, cacheRead: 0.125),
        "gpt-5.1":            ModelPricing.Pricing(input: 1.25, output: 10.0, cacheWrite5m: 1.25, cacheWrite1h: 1.25, cacheRead: 0.125),
        "gpt-5.4":            ModelPricing.Pricing(input: 2.50, output: 15.0, cacheWrite5m: 2.50, cacheWrite1h: 2.50, cacheRead: 0.25),
        "gpt-5.4-mini":       ModelPricing.Pricing(input: 0.75, output: 4.50, cacheWrite5m: 0.75, cacheWrite1h: 0.75, cacheRead: 0.075),
        "gpt-5-codex":        ModelPricing.Pricing(input: 1.25, output: 10.0, cacheWrite5m: 1.25, cacheWrite1h: 1.25, cacheRead: 0.125),
        "gpt-5.1-codex":      ModelPricing.Pricing(input: 1.25, output: 10.0, cacheWrite5m: 1.25, cacheWrite1h: 1.25, cacheRead: 0.125),
        "gpt-5.1-codex-max":  ModelPricing.Pricing(input: 1.25, output: 10.0, cacheWrite5m: 1.25, cacheWrite1h: 1.25, cacheRead: 0.125),
        "gpt-5.1-codex-mini": ModelPricing.Pricing(input: 0.25, output: 2.0, cacheWrite5m: 0.25, cacheWrite1h: 0.25, cacheRead: 0.025),
        "gpt-5.2-codex":      ModelPricing.Pricing(input: 1.75, output: 14.0, cacheWrite5m: 1.75, cacheWrite1h: 1.75, cacheRead: 0.175),
        "gpt-5.3-codex":      ModelPricing.Pricing(input: 1.75, output: 14.0, cacheWrite5m: 1.75, cacheWrite1h: 1.75, cacheRead: 0.175),
    ]
}
