import AppKit
import Foundation

struct ITermTerminalCapability: TerminalCapability, TerminalLaunching, TerminalFocusCapabilityProviding, TerminalDirectFocusing, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.iTermOptionID
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
