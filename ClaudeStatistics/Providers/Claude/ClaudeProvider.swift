import Foundation

final class ClaudeProvider: SessionProvider, @unchecked Sendable {
    static let shared = ClaudeProvider()

    let kind: ProviderKind = .claude
    let displayName = ProviderKind.claude.displayName
    let capabilities = ProviderCapabilities.claude
    let usageSource: (any ProviderUsageSource)? = UsageAPIService.shared
    let configDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    let builtinPricingModels = ClaudePricingCatalog.builtinModels

    var credentialStatus: Bool? { CredentialService.shared.getAccessToken() != nil }
    var statusLineInstaller: (any StatusLineInstalling)? { ClaudeStatusLineAdapter() }
    var notchHookInstaller: (any HookInstalling)? { ClaudeHookInstaller() }
    var supportedNotchEvents: Set<NotchEventKind> { [.permission, .waitingInput, .taskDone, .taskFailed] }
    var pricingFetcher: (any ProviderPricingFetching)? { PricingFetchService.shared }
    var pricingSourceLocalizationKey: String? { "pricing.source.claude" }
    var pricingSourceURL: URL? { URL(string: "https://docs.anthropic.com/en/docs/about-claude/pricing") }
    var pricingUpdatedLocalizationKey: String? { "pricing.updated.claude" }
    var credentialHintLocalizationKey: String? {
        switch ClaudeAccountModeController.shared.mode {
        case .independent: return "settings.credentialHint.claude.independent"
        case .sync: return "settings.credentialHint.claude"
        }
    }

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

    func changedSessionIds(for changedPaths: Set<String>) -> Set<String> {
        Set(changedPaths.compactMap { SessionScanner.uniqueSessionId(forTranscriptPath: $0) })
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

    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        TranscriptParser.shared.parseSearchIndexMessages(at: path)
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        TranscriptParser.shared.parseTrendData(from: filePath, granularity: granularity)
    }

    func openNewSession(_ session: Session) {
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "claude",
                arguments: [],
                cwd: resolvedProjectPath(for: session)
            )
        )
    }

    func resumeSession(_ session: Session) {
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "claude",
                arguments: ["--resume", session.externalID],
                cwd: resolvedProjectPath(for: session)
            )
        )
    }

    func resumeCommand(for session: Session) -> String {
        TerminalLaunchRequest(
            executable: "claude",
            arguments: ["--resume", session.externalID],
            cwd: resolvedProjectPath(for: session)
        ).commandInWorkingDirectory
    }

    func openNewSession(inDirectory path: String) {
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "claude",
                arguments: [],
                cwd: path
            )
        )
    }
}

// MARK: - Tool name canonicalization

/// Claude's native tool names already match the shared canonical vocabulary
/// (`Edit`, `Read`, `Write`, `Bash`, …), so there are no aliases to rewrite.
/// Claude-only tools that fall outside the shared vocabulary (`TodoWrite`,
/// `EnterPlanMode`, `ExitPlanMode`) simply pass through as-is.
enum ClaudeToolNames {
    static func canonical(_ normalized: String) -> String? {
        nil
    }
}

// MARK: - StatusLine adapter

struct ClaudeStatusLineAdapter: StatusLineInstalling {
    var isInstalled: Bool { StatusLineInstaller.isInstalled }
    var hasRestoreOption: Bool { StatusLineInstaller.hasBackup }
    var titleLocalizationKey: String { "statusLine.title" }
    var descriptionLocalizationKey: String { "statusLine.description" }
    var legendSections: [StatusLineLegendSection] {
        [
            StatusLineLegendSection(
                titleLocalizationKey: "statusLine.legend.section.metrics",
                items: [
                    StatusLineLegendItem(example: "5h 42%(3h20m)", descriptionLocalizationKey: "statusLine.legend.metric.fiveHour"),
                    StatusLineLegendItem(example: "7d 38%(2d4h)", descriptionLocalizationKey: "statusLine.legend.metric.sevenDay"),
                    StatusLineLegendItem(example: "↑ 128k  ↓ 24k", descriptionLocalizationKey: "statusLine.legend.metric.tokens"),
                    StatusLineLegendItem(example: "⇡ 8k  ⇣ 120k", descriptionLocalizationKey: "statusLine.legend.metric.cache")
                ]
            ),
            StatusLineLegendSection(
                titleLocalizationKey: "statusLine.legend.section.git",
                items: [
                    StatusLineLegendItem(example: "✓", descriptionLocalizationKey: "statusLine.legend.git.clean"),
                    StatusLineLegendItem(example: "×", descriptionLocalizationKey: "statusLine.legend.git.dirty"),
                    StatusLineLegendItem(example: "ahead:2 behind:1", descriptionLocalizationKey: "statusLine.legend.git.sync"),
                    StatusLineLegendItem(example: "stage:3", descriptionLocalizationKey: "statusLine.legend.git.staged"),
                    StatusLineLegendItem(example: "mod:2", descriptionLocalizationKey: "statusLine.legend.git.modified"),
                    StatusLineLegendItem(example: "new:1", descriptionLocalizationKey: "statusLine.legend.git.untracked"),
                    StatusLineLegendItem(example: "stash:4", descriptionLocalizationKey: "statusLine.legend.git.stash")
                ]
            )
        ]
    }
    func install() throws { try StatusLineInstaller.install() }
    func restore() throws { try StatusLineInstaller.restore() }
}

enum ClaudePricingCatalog {
    // Source: Anthropic Claude pricing (2026-03-20)
    static let builtinModels: [String: ModelPricing.Pricing] = [
        "claude-opus-4-7":            ModelPricing.Pricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
        "claude-opus-4-6":            ModelPricing.Pricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
        "claude-opus-4-5-20251101":   ModelPricing.Pricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
        "claude-opus-4-1-20250805":   ModelPricing.Pricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
        "claude-opus-4-20250514":     ModelPricing.Pricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
        "claude-sonnet-4-6":          ModelPricing.Pricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
        "claude-sonnet-4-5-20250929": ModelPricing.Pricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
        "claude-sonnet-4-20250514":   ModelPricing.Pricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
        "claude-haiku-4-5-20251001":  ModelPricing.Pricing(input: 1.0, output: 5.0, cacheWrite5m: 1.25, cacheWrite1h: 2.0, cacheRead: 0.10),
        "claude-3-5-haiku-20241022":  ModelPricing.Pricing(input: 0.80, output: 4.0, cacheWrite5m: 1.0, cacheWrite1h: 1.60, cacheRead: 0.08),
        "claude-3-haiku-20240307":    ModelPricing.Pricing(input: 0.25, output: 1.25, cacheWrite5m: 0.3125, cacheWrite1h: 0.50, cacheRead: 0.025),
    ]
}
