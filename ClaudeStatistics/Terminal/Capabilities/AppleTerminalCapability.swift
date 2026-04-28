import Foundation
import ClaudeStatisticsKit

struct AppleTerminalCapability: TerminalCapability, TerminalLauncher, TerminalFocusCapabilityProviding, TerminalDirectFocusing, TerminalReadinessProviding {
    let optionID: String? = "Terminal"
    let category: TerminalCapabilityCategory = .terminal
    let displayName = "Terminal"
    let bundleIdentifiers: Set<String> = ["com.apple.Terminal"]
    let terminalNameAliases: Set<String> = ["apple_terminal", "terminal", "apple terminal"]
    let processNameHints: Set<String> = ["terminal"]
    let route: TerminalFocusRoute = .appleScript
    let tabFocusPrecision: TerminalTabFocusPrecision = .exact
    let autoLaunchPriority: Int? = 70

    var isInstalled: Bool { true }

    func launch(_ request: TerminalLaunchRequest) {
        let command = TerminalShellCommand.escapeAppleScript(request.commandInWorkingDirectory)
        // `do script X in window N` opens a new *tab* in that window; plain
        // `do script X` opens a fresh window. Prefer the tab form when one
        // already exists so users don't accumulate windows.
        let script = """
        tell application "Terminal"
            activate
            if (count of windows) > 0 then
                do script "\(command)" in window 1
            else
                do script "\(command)"
            end if
        end tell
        """
        TerminalAppleScriptRunner.run(script)
    }

    func focusCapability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        let hasLocator = target.tty != nil
            || target.projectPath != nil
            || target.terminalWindowID != nil
            || target.terminalTabID != nil
            || target.terminalStableID != nil
        return hasLocator ? .ready : .appOnly
    }

    func directFocus(_ target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        let result = AppleScriptFocuser.focus(
            bundleId: primaryBundleIdentifier,
            tty: target.tty,
            projectPath: target.projectPath,
            terminalWindowID: target.terminalWindowID,
            terminalTabID: target.terminalTabID,
            stableTerminalID: target.terminalStableID
        )
        guard case .success(let resolvedStableID) = result else {
            return nil
        }
        return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: resolvedStableID)
    }

    func installationStatus() -> TerminalInstallationStatus {
        .installed
    }

    func setupRequirements() -> [TerminalRequirement] {
        []
    }

    func setupActions() -> [TerminalSetupAction] {
        [openPrimaryAppAction(id: "terminal.open", title: "Open Terminal")].compactMap { $0 }
    }
}

extension AppleTerminalCapability: TerminalFrontmostSessionProbing {
    var frontmostFocusedSessionScript: String {
        """
        tell application "Terminal"
            if not frontmost then return ""
            try
                return "|" & (tty of selected tab of front window as text)
            end try
        end tell
        return ""
        """
    }
}

extension AppleTerminalCapability: TerminalAppleScriptContainsProbing {
    func containsSessionScript(
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> String? {
        guard let tty, !tty.isEmpty else { return nil }
        return """
        set targetTtys to \(AppleScriptHelpers.ttyListLiteral(tty))
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if targetTtys contains (tty of t as text) then return "ok"
                    end try
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }
}
