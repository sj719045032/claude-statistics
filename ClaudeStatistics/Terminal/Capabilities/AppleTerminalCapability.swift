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
