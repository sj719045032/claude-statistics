import AppKit
import ClaudeStatisticsKit
import Foundation

/// First external Terminal plugin: Anthropic's Claude desktop app.
///
/// The host's `ProcessTreeWalker` ascends the parent process chain at
/// notch-click time looking for a "terminal-like" bundle to activate.
/// Sessions started from inside Claude.app would otherwise stop at a
/// non-terminal ancestor and the click went nowhere ("空岛"). This
/// plugin teaches the host that `com.anthropic.claudefordesktop` is a
/// valid focus target, then routes focus to a precise per-session
/// deep link instead of just activating the app — Claude.app exposes
/// `claude://claude.ai/resume?session=<id>` natively for CLI sessions,
/// and the CLI's transcript file name uses that same UUID.
@objc(ClaudeAppPlugin)
public final class ClaudeAppPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.anthropic.claudefordesktop",
        kind: .terminal,
        displayName: "Claude",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "ClaudeAppPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "com.anthropic.claudefordesktop",
        displayName: "Claude",
        category: .terminal,
        bundleIdentifiers: ["com.anthropic.claudefordesktop"],
        terminalNameAliases: ["claude", "claude.app"],
        processNameHints: ["claude"],
        focusPrecision: .exact,
        autoLaunchPriority: nil
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifiers.first ?? "") != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        ClaudeAppFocusStrategy()
    }
}

struct ClaudeAppFocusStrategy: TerminalFocusStrategy {
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
           let url = URL(string: "claude://claude.ai/resume?session=\(sessionId)"),
           NSWorkspace.shared.open(url) {
            return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: sessionId)
        }
        if let url = URL(string: "claude://"), NSWorkspace.shared.open(url) {
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
        }
        return TerminalFocusExecutionResult(capability: .unresolved, resolvedStableID: nil)
    }
}
