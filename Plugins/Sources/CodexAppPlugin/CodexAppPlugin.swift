import AppKit
import ClaudeStatisticsKit
import Foundation

/// First external Terminal plugin (companion to ClaudeAppPlugin):
/// OpenAI's Codex desktop app.
///
/// Codex.app exposes `codex://threads/<uuid>` natively (the in-app
/// menu literally has a "Copy deeplink" entry), and the Codex CLI
/// rollout filename embeds the same UUID — so the notch click can
/// land directly on the matching thread instead of merely activating
/// the app.
@objc(CodexAppPlugin)
public final class CodexAppPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.openai.codex",
        kind: .terminal,
        displayName: "Codex",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "CodexAppPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "com.openai.codex",
        displayName: "Codex",
        category: .terminal,
        bundleIdentifiers: ["com.openai.codex"],
        terminalNameAliases: ["codex", "codex.app"],
        processNameHints: ["codex"],
        focusPrecision: .exact,
        autoLaunchPriority: nil
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifiers.first ?? "") != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        CodexAppFocusStrategy()
    }

    /// Codex.app fires a fresh `codex-cli` subprocess (with a new
    /// session id) every time it generates "Ambient Suggestions" for
    /// the current project; the prompt is a fixed template the host
    /// app injects. The behaviour is owned by the host (codex-cli
    /// alone never produces these), so the filter ships with this
    /// terminal plugin — install Codex.app, get the filter; remove
    /// it, the rule goes too.
    public func makeSessionFilters() -> [any SessionEventFilter] {
        [
            SyntheticPromptFilter(
                id: "codex-app.ambient-suggestions",
                providerId: "codex",
                prefixes: ["Generate 0 to 3 ambient suggestions"]
            )
        ]
    }
}

struct CodexAppFocusStrategy: TerminalFocusStrategy {
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        target.sessionId?.isEmpty == false ? .ready : .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await activate(sessionId: target.sessionId)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await activate(sessionId: target.sessionId)
    }

    @MainActor
    private func activate(sessionId: String?) -> TerminalFocusExecutionResult {
        if let sessionId, !sessionId.isEmpty,
           let url = URL(string: "codex://threads/\(sessionId)"),
           NSWorkspace.shared.open(url) {
            return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: sessionId)
        }
        if let url = URL(string: "codex://"), NSWorkspace.shared.open(url) {
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
        }
        return TerminalFocusExecutionResult(capability: .unresolved, resolvedStableID: nil)
    }
}
