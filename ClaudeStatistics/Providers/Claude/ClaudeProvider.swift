import Foundation
import ClaudeStatisticsKit

final class ClaudeProvider: SessionProvider, @unchecked Sendable {
    static let shared = ClaudeProvider()

    let kind: ProviderKind = .claude
    var providerId: String { kind.rawValue }
    let displayName = ProviderKind.claude.descriptor.displayName
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
    var pricingSourceURL: URL? { URL(string: "https://platform.claude.com/docs/en/about-claude/pricing") }
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
        let fileManager = FileManager.default
        var watchers: [any SessionWatcher] = []

        let projectsDir = (CredentialService.shared.claudeConfigDir() as NSString).appendingPathComponent("projects")
        if fileManager.fileExists(atPath: projectsDir) {
            watchers.append(FSEventsWatcher(path: projectsDir, debounceSeconds: 2.0, onChange: onChange))
        }

        if let coworkWatchDirectory = SessionScanner.shared.coworkWatchDirectory {
            watchers.append(FSEventsWatcher(
                path: coworkWatchDirectory,
                debounceSeconds: 2.0,
                fileFilter: { SessionScanner.shared.isCoworkTranscriptPath($0) },
                onChange: onChange
            ))
        }

        guard !watchers.isEmpty else { return nil }
        if watchers.count == 1 { return watchers[0] }
        return CompositeSessionWatcher(watchers: watchers)
    }

    func changedSessionIds(for changedPaths: Set<String>) -> Set<String> {
        Set(changedPaths.compactMap { SessionScanner.shared.uniqueSessionId(forTranscriptPath: $0) })
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

    func parseSessionAndSearchIndex(at path: String) -> SessionParseResult {
        TranscriptParser.shared.parseSessionAndSearchIndex(at: path)
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        TranscriptParser.shared.parseTrendData(from: filePath, granularity: granularity)
    }

    func parseSessionIncremental(
        fromData data: Data,
        fromOffset: Int64,
        existingStats: SessionStats,
        path: String
    ) -> IncrementalParseResult? {
        TranscriptParser.shared.parseSessionIncremental(
            fromData: data, fromOffset: fromOffset,
            existingStats: existingStats, path: path
        )
    }

    func openNewSession(_ session: Session) {
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "claude",
                arguments: [],
                cwd: resolvedProjectPath(for: session),
                intent: .newSession(metadata: session.metadata)
            ),
            preferredOptionID: TerminalPreferences.preferredOptionID(forProvider: providerId)
        )
    }

    func resumeSession(_ session: Session) {
        guard session.isResumable else { return }
        TerminalRegistry.launch(
            TerminalLaunchRequest(
                executable: "claude",
                arguments: ["--resume", session.externalID],
                cwd: resolvedProjectPath(for: session),
                intent: .resumeSession(sessionID: session.externalID, metadata: session.metadata)
            ),
            preferredOptionID: TerminalPreferences.preferredOptionID(forProvider: providerId)
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
                cwd: path,
                intent: .newSession()
            ),
            preferredOptionID: TerminalPreferences.preferredOptionID(forProvider: providerId)
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
    // Source: Anthropic Claude pricing (2026-07-10)
    static var builtinModels: [String: ModelPricing.Pricing] {
        models(at: Date())
    }

    static let sonnet5StandardPricingStart = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC
    static let sonnet5IntroPricing = ModelPricing.Pricing(
        input: 2.0, output: 10.0,
        cacheWrite5m: 2.50, cacheWrite1h: 4.0, cacheRead: 0.20
    )
    static let sonnet5StandardPricing = ModelPricing.Pricing(
        input: 3.0, output: 15.0,
        cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30
    )

    static func models(at date: Date) -> [String: ModelPricing.Pricing] {
        [
            "claude-fable-5":             ModelPricing.Pricing(input: 10.0, output: 50.0, cacheWrite5m: 12.50, cacheWrite1h: 20.0, cacheRead: 1.0),
            "claude-mythos-5":            ModelPricing.Pricing(input: 10.0, output: 50.0, cacheWrite5m: 12.50, cacheWrite1h: 20.0, cacheRead: 1.0),
            "claude-opus-4-8":            ModelPricing.Pricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-7":            ModelPricing.Pricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-6":            ModelPricing.Pricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-5-20251101":   ModelPricing.Pricing(input: 5.0, output: 25.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-1-20250805":   ModelPricing.Pricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
            "claude-opus-4-20250514":     ModelPricing.Pricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
            "claude-sonnet-5":            date < sonnet5StandardPricingStart ? sonnet5IntroPricing : sonnet5StandardPricing,
            "claude-sonnet-4-6":          ModelPricing.Pricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
            "claude-sonnet-4-5-20250929": ModelPricing.Pricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
            "claude-sonnet-4-20250514":   ModelPricing.Pricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30),
            "claude-haiku-4-5-20251001":  ModelPricing.Pricing(input: 1.0, output: 5.0, cacheWrite5m: 1.25, cacheWrite1h: 2.0, cacheRead: 0.10),
            "claude-3-5-haiku-20241022":  ModelPricing.Pricing(input: 0.80, output: 4.0, cacheWrite5m: 1.0, cacheWrite1h: 1.60, cacheRead: 0.08),
            "claude-3-haiku-20240307":    ModelPricing.Pricing(input: 0.25, output: 1.25, cacheWrite5m: 0.3125, cacheWrite1h: 0.50, cacheRead: 0.025),
        ]
    }
}
