import Foundation
import ClaudeStatisticsKit

final class GeminiProvider: SessionDataProvider, UsageProvider, AccountProvider, HookProvider, SessionLauncher, @unchecked Sendable {
    static let shared = GeminiProvider()

    var providerId: String { "gemini" }
    let displayName = "Gemini"
    let capabilities = ProviderCapabilities(
        supportsCost: true,
        supportsUsage: true,
        supportsProfile: true,
        supportsStatusLine: true,
        supportsExactPricing: false,
        supportsResume: true,
        supportsNewSession: true
    )
    let usageSource: (any ProviderUsageSource)? = GeminiUsageService.shared
    let configDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini")
    let builtinPricingModels = GeminiPricingCatalog.builtinModels
    let usagePresentation = ProviderUsagePresentation.gemini
    var credentialStatus: Bool? { GeminiUsageService.shared.hasUsableCredentials }
    var statusLineInstaller: (any StatusLineInstalling)? { GeminiStatusLineAdapter() }
    var notchHookInstaller: (any HookInstalling)? { GeminiHookInstaller() }
    // Gemini permission prompts are passive notifications: the app can surface
    // them, but approval still has to happen in the terminal.
    var supportedNotchEvents: Set<NotchEventKind> { [.permission, .taskDone] }
    var pricingFetcher: (any ProviderPricingFetching)? { GeminiPricingFetchService.shared }
    var pricingSourceLocalizationKey: String? { "pricing.source.gemini" }
    var pricingSourceURL: URL? { URL(string: "https://ai.google.dev/gemini-api/docs/pricing") }
    var pricingUpdatedLocalizationKey: String? { "pricing.updated.gemini" }
    var credentialHintLocalizationKey: String? { "settings.credentialHint.gemini" }
    let alwaysRescanOnFileChanges = true

    private init() {}

    func fetchProfile() async -> UserProfile? {
        await GeminiUsageService.shared.fetchProfile()
    }

    func resolvedProjectPath(for session: Session) -> String {
        session.cwd ?? session.projectPath
    }

    func scanSessions() -> [Session] {
        GeminiSessionScanner.shared.scanSessions()
    }

    func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/tmp")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return FSEventsWatcher(
            path: path,
            debounceSeconds: 2.0,
            fileFilter: { $0.hasSuffix(".json") && $0.contains("/chats/") },
            onChange: onChange
        )
    }

    func changedSessionIds(for changedPaths: Set<String>) -> Set<String> {
        var ids: Set<String> = []
        for path in changedPaths {
            guard path.hasSuffix(".json"),
                  path.contains("/chats/"),
                  let session = GeminiTranscriptParser.shared.loadSession(at: path) else {
                continue
            }
            ids.insert(session.sessionId)
        }
        return ids
    }

    func parseQuickStats(at path: String) -> SessionQuickStats {
        GeminiTranscriptParser.shared.parseSessionQuick(at: path)
    }

    func parseSession(at path: String) -> SessionStats {
        GeminiTranscriptParser.shared.parseSession(at: path)
    }

    func parseMessages(at path: String) -> [TranscriptDisplayMessage] {
        GeminiTranscriptParser.shared.parseMessages(at: path)
    }

    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        GeminiTranscriptParser.shared.parseSearchIndexMessages(at: path)
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        GeminiTranscriptParser.shared.parseTrendData(from: filePath, granularity: granularity)
    }

    func openNewSession(_ session: Session) {
        TerminalDispatch.launch(
            TerminalLaunchRequest(
                executable: "gemini",
                arguments: [],
                cwd: resolvedProjectPath(for: session)
            )
        )
    }

    func resumeSession(_ session: Session) {
        TerminalDispatch.launch(
            TerminalLaunchRequest(
                executable: "gemini",
                arguments: ["resume", session.externalID],
                cwd: resolvedProjectPath(for: session)
            )
        )
    }

    func resumeCommand(for session: Session) -> String {
        TerminalLaunchRequest(
            executable: "gemini",
            arguments: ["resume", session.externalID],
            cwd: resolvedProjectPath(for: session)
        ).commandInWorkingDirectory
    }

    func openNewSession(inDirectory path: String) {
        TerminalDispatch.launch(
            TerminalLaunchRequest(
                executable: "gemini",
                arguments: [],
                cwd: path
            )
        )
    }
}

// MARK: - Tool name canonicalization

/// Maps Gemini's raw tool names (`run_shell_command`, `read_file`, …) onto
/// the shared canonical vocabulary (`bash`, `read`, …). Input is expected to
/// be the lower-cased/underscore-normalized form that
/// `ProviderDescriptor.canonicalToolName(_:)` produces; returns `nil` when
/// no alias applies so the caller can keep the original name.
///
/// `table` is the source of truth — `canonical(_:)` is a thin wrapper
/// for plugin-internal callers, and `GeminiPlugin.init()` registers
/// the same dictionary into `PluginToolAliasStore` so the host
/// descriptor's alias closure can resolve through it without holding
/// a duplicate copy.
enum GeminiToolNames {
    static let table: [String: String] = [
        "run_shell_command":     "bash",
        "grep_search":           "grep",
        "read_file":             "read",
        "write_file":            "write",
        "replace":               "edit",
        "web_fetch":             "webfetch",
        "web_search":            "websearch",
        "google_web_search":     "websearch",
        "google_search":         "websearch",
        "list_directory":        "ls",
        "codebase_investigator": "agent",
        "cli_help":              "help",
    ]

    static func canonical(_ normalized: String) -> String? {
        table[normalized]
    }
}

struct GeminiStatusLineAdapter: StatusLineInstalling {
    var isInstalled: Bool { GeminiStatusLineInstaller.isInstalled }
    var hasRestoreOption: Bool { GeminiStatusLineInstaller.hasBackup }
    var titleLocalizationKey: String { "statusLine.gemini.title" }
    var descriptionLocalizationKey: String { "statusLine.gemini.description" }
    var legendSections: [StatusLineLegendSection] {
        [
            StatusLineLegendSection(
                titleLocalizationKey: "statusLine.legend.section.gemini",
                items: [
                    StatusLineLegendItem(example: "workspace", descriptionLocalizationKey: "statusLine.legend.gemini.workspace"),
                    StatusLineLegendItem(example: "gemini-2.5-pro", descriptionLocalizationKey: "statusLine.legend.gemini.model"),
                    StatusLineLegendItem(example: "quota 58%", descriptionLocalizationKey: "statusLine.legend.gemini.quota"),
                    StatusLineLegendItem(example: "auth / sandbox", descriptionLocalizationKey: "statusLine.legend.gemini.state")
                ]
            )
        ]
    }
    func install() throws { try GeminiStatusLineInstaller.install() }
    func restore() throws { try GeminiStatusLineInstaller.restore() }
}

enum GeminiPricingCatalog {
    // Source: Google Gemini API pricing page verified on 2026-04-14.
    static let builtinModels: [String: ModelPricingRates] = [
        // 2.5
        "gemini-2.5-pro":                    ModelPricingRates(input: 1.25, output: 10.0, cacheWrite5m: 0.125, cacheWrite1h: 0.25, cacheRead: 0.125),
        "gemini-2.5-flash":                  ModelPricingRates(input: 0.30, output: 2.50, cacheWrite5m: 0.03, cacheWrite1h: 0.03, cacheRead: 0.03),
        "gemini-2.5-flash-preview-09-2025":  ModelPricingRates(input: 0.30, output: 2.50, cacheWrite5m: 0.03, cacheWrite1h: 0.03, cacheRead: 0.03),
        "gemini-2.5-flash-lite":             ModelPricingRates(input: 0.10, output: 0.40, cacheWrite5m: 0.01, cacheWrite1h: 0.01, cacheRead: 0.01),
        "gemini-2.5-flash-lite-preview-09-2025": ModelPricingRates(input: 0.10, output: 0.40, cacheWrite5m: 0.01, cacheWrite1h: 0.01, cacheRead: 0.01),
        // 3.x
        "gemini-3.1-pro-preview":            ModelPricingRates(input: 2.0, output: 12.0, cacheWrite5m: 0.20, cacheWrite1h: 0.40, cacheRead: 0.20),
        "gemini-3.1-pro-preview-customtools": ModelPricingRates(input: 2.0, output: 12.0, cacheWrite5m: 0.20, cacheWrite1h: 0.40, cacheRead: 0.20),
        "gemini-3.1-flash-lite-preview":     ModelPricingRates(input: 0.25, output: 1.50, cacheWrite5m: 0.025, cacheWrite1h: 0.025, cacheRead: 0.025),
        "gemini-3-flash-preview":            ModelPricingRates(input: 0.50, output: 3.00, cacheWrite5m: 0.05, cacheWrite1h: 0.05, cacheRead: 0.05),
        // Historical alias seen in local CLI sessions. Current docs expose 3.1 Pro Preview.
        "gemini-3-pro-preview":              ModelPricingRates(input: 2.0, output: 12.0, cacheWrite5m: 0.20, cacheWrite1h: 0.40, cacheRead: 0.20),
    ]
}
