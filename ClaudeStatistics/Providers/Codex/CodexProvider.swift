import Foundation

final class CodexProvider: SessionProvider, @unchecked Sendable {
    static let shared = CodexProvider()

    let kind: ProviderKind = .codex
    let displayName = ProviderKind.codex.displayName
    let capabilities = ProviderCapabilities.codex
    let usageSource: (any ProviderUsageSource)? = CodexUsageService.shared
    let configDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    let builtinPricingModels = CodexPricingCatalog.builtinModels

    // credentialStatus: nil — Codex profile is decoded locally, no explicit credential check needed
    var statusLineInstaller: (any StatusLineInstalling)? { CodexStatusLineAdapter() }
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

    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        CodexTranscriptParser.shared.parseSearchIndexMessages(at: path)
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        CodexTranscriptParser.shared.parseTrendData(from: filePath, granularity: granularity)
    }

    func openNewSession(_ session: Session) {
        TerminalLauncher.launch(executable: "codex", arguments: [], cwd: resolvedProjectPath(for: session))
    }

    func resumeSession(_ session: Session) {
        TerminalLauncher.launch(executable: "codex", arguments: ["resume", session.externalID], cwd: resolvedProjectPath(for: session))
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
