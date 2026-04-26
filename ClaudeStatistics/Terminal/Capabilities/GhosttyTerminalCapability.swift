import AppKit
import ClaudeStatisticsKit
import Foundation

struct GhosttyTerminalCapability: TerminalCapability, TerminalLaunching, TerminalFocusCapabilityProviding, TerminalDirectFocusing, TerminalFocusIdentityProviding, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.ghosttyOptionID
    let category: TerminalCapabilityCategory = .terminal
    let displayName = "Ghostty"
    let bundleIdentifiers: Set<String> = ["com.mitchellh.ghostty"]
    let terminalNameAliases: Set<String> = ["ghostty", "xterm-ghostty"]
    let processNameHints: Set<String> = ["ghostty"]
    let route: TerminalFocusRoute = .appleScript
    let tabFocusPrecision: TerminalTabFocusPrecision = .bestEffort
    let autoLaunchPriority: Int? = 10

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
    }

    func launch(_ request: TerminalLaunchRequest) {
        // Bootstrap via a tiny script that Ghostty "opens" through the
        // macOS open-doc Apple Event. The script MUST live under
        // `request.cwd`: Ghostty uses the file's parent directory as the
        // new tab's working directory, so dropping it anywhere else (e.g.
        // ~/.claude-statistics/run) leaves the tab in the wrong cwd and
        // breaks every cwd-based focus/match path downstream.
        //
        // Why not `open -na Ghostty.app --args ...`? `-n` spawns a brand-
        // new Ghostty daemon every time, which then lives in parallel to
        // the user's existing Ghostty — AppleScript focus can only target
        // one, and the other instance's tabs become unreachable by id.
        // Dropping `-n` makes args silently ignored for already-running
        // apps. And `-e <cmd>` triggers Ghostty's per-launch security
        // prompt.
        let expandedCwd = (request.cwd as NSString).expandingTildeInPath
        let scriptPath = (expandedCwd as NSString).appendingPathComponent(".cs-launch")
        let content = """
        #!/bin/zsh -l
        rm -f \(TerminalShellCommand.escape(scriptPath))
        cd \(TerminalShellCommand.escape(expandedCwd)) || exit 1
        exec \(request.commandOnly)
        """
        guard (try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)) != nil
        else { return }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            ?? URL(fileURLWithPath: "/Applications/Ghostty.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: scriptPath)],
            withApplicationAt: appURL,
            configuration: configuration
        )
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

    func shouldUseCachedIdentity(
        requestedWindowID: String?,
        requestedTabID: String?,
        requestedStableID: String?,
        cachedTarget: TerminalFocusTarget?
    ) -> Bool {
        requestedWindowID?.nilIfEmpty != nil
            || requestedTabID?.nilIfEmpty != nil
            || requestedStableID?.nilIfEmpty != nil
            || cachedTarget?.terminalWindowID?.nilIfEmpty != nil
            || cachedTarget?.terminalTabID?.nilIfEmpty != nil
            || cachedTarget?.terminalStableID?.nilIfEmpty != nil
    }

    func cachedFocusTarget(
        from target: TerminalFocusTarget,
        resolvedStableID: String?
    ) -> TerminalFocusTarget {
        target.withStableTerminalID(
            resolvedStableID ?? target.terminalStableID,
            capturedAt: Date()
        )
    }

    func focusTargetAfterDirectFocusFailure(
        _ target: TerminalFocusTarget,
        cachedTarget: TerminalFocusTarget?
    ) -> TerminalFocusTarget? {
        guard target.terminalStableID?.nilIfEmpty != nil
                || target.terminalTabID?.nilIfEmpty != nil
                || target.terminalWindowID?.nilIfEmpty != nil,
              let cachedTarget else {
            return nil
        }
        return cachedTarget
            .clearingTerminalIdentity(capturedAt: Date())
            .withResolvedCapability()
    }

    func acceptsResolvedStableID(
        _ resolvedStableID: String?,
        for target: TerminalFocusTarget
    ) -> Bool {
        guard let requestedStableID = target.terminalStableID?.nilIfEmpty else {
            return true
        }
        return resolvedStableID?.nilIfEmpty == requestedStableID
    }

    func installationStatus() -> TerminalInstallationStatus {
        installedStatus
    }

    func setupRequirements() -> [TerminalRequirement] {
        defaultInstallationRequirements()
    }

    func setupActions() -> [TerminalSetupAction] {
        [openPrimaryAppAction(id: "ghostty.open", title: "Open Ghostty")].compactMap { $0 }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
