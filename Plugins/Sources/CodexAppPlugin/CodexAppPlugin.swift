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
public final class CodexAppPlugin: TerminalPlugin {
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

    public init() {}

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifiers.first ?? "") != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        CodexAppFocusStrategy()
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
