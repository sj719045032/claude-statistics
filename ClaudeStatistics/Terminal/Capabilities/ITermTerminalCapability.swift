import AppKit
import ClaudeStatisticsKit
import Foundation

struct ITermTerminalCapability: TerminalCapability, TerminalLauncher, TerminalFocusCapabilityProviding, TerminalDirectFocusing, TerminalReadinessProviding {
    let optionID: String? = "iTerm2"
    let category: TerminalCapabilityCategory = .terminal
    let displayName = "iTerm2"
    let bundleIdentifiers: Set<String> = ["com.googlecode.iterm2"]
    let terminalNameAliases: Set<String> = ["iterm", "iterm.app", "iterm2"]
    let processNameHints: Set<String> = ["iterm"]
    let route: TerminalFocusRoute = .appleScript
    let tabFocusPrecision: TerminalTabFocusPrecision = .exact
    let autoLaunchPriority: Int? = 30

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    func launch(_ request: TerminalLaunchRequest) {
        let command = TerminalShellCommand.escapeAppleScript(request.commandInWorkingDirectory)
        // Prefer opening a new tab in the current window to avoid piling up
        // windows. Fall back to `create window` only when iTerm has none.
        let script = """
        tell application "iTerm"
            activate
            if (count of windows) > 0 then
                tell current window
                    create tab with default profile
                end tell
                tell current session of current window
                    write text "\(command)"
                end tell
            else
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(command)"
                end tell
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
        installedStatus
    }

    func setupRequirements() -> [TerminalRequirement] {
        defaultInstallationRequirements()
    }

    func setupActions() -> [TerminalSetupAction] {
        [openPrimaryAppAction(id: "iterm.open", title: "Open iTerm2")].compactMap { $0 }
    }
}

extension ITermTerminalCapability: TerminalFrontmostSessionProbing {
    var frontmostFocusedSessionScript: String {
        """
        tell application "iTerm2"
            if not frontmost then return ""
            try
                set s to current session of current tab of current window
                return (id of s as text) & "|" & (tty of s as text)
            end try
        end tell
        return ""
        """
    }
}

extension ITermTerminalCapability: TerminalAppleScriptContainsProbing {
    func containsSessionScript(
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> String? {
        let trimmedTTY = (tty?.isEmpty == false) ? tty : nil
        let trimmedStable = (stableTerminalID?.isEmpty == false) ? stableTerminalID : nil
        guard trimmedTTY != nil || trimmedStable != nil else { return nil }

        let stableIDClause: String
        if let stableTerminalID = trimmedStable {
            stableIDClause = """
            if (id of s as text) is "\(AppleScriptHelpers.escape(stableTerminalID))" then return "ok"
            """
        } else {
            stableIDClause = ""
        }

        let ttyClause: String
        if trimmedTTY != nil {
            ttyClause = """
            if targetTtys contains (tty of s as text) then return "ok"
            """
        } else {
            ttyClause = ""
        }

        return """
        set targetTtys to \(trimmedTTY.map(AppleScriptHelpers.ttyListLiteral) ?? "{}")
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            \(stableIDClause)
                            \(ttyClause)
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }
}
