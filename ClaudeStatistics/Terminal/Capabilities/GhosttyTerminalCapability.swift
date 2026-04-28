import AppKit
import ClaudeStatisticsKit
import Foundation

struct GhosttyTerminalCapability: TerminalCapability, TerminalLauncher, TerminalFocusCapabilityProviding, TerminalDirectFocusing, TerminalFocusIdentityProviding, TerminalReadinessProviding {
    let optionID: String? = "Ghostty"
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

extension GhosttyTerminalCapability: TerminalFrontmostSessionProbing {
    var frontmostFocusedSessionScript: String {
        """
        tell application id "com.mitchellh.ghostty"
            if not frontmost then return ""
            try
                set terminalRef to focused terminal of selected tab of front window
                return (id of terminalRef as text) & "|"
            end try
        end tell
        return ""
        """
    }
}

extension GhosttyTerminalCapability: TerminalAppleScriptFocusing {
    func focusSessionScript(
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> String? {
        let trimmedWindow = terminalWindowID?.nilIfEmpty
        let trimmedTab = terminalTabID?.nilIfEmpty
        let trimmedStable = stableTerminalID?.nilIfEmpty
        let trimmedPath = projectPath?.nilIfEmpty

        // Match the original focuser logic: an explicit window/tab/stable
        // locator is enough; otherwise we need a project path to scan
        // working dirs against. With nothing useful, bail.
        let hasExplicitLocator = trimmedWindow != nil || trimmedTab != nil || trimmedStable != nil
        guard hasExplicitLocator || trimmedPath != nil else { return nil }

        let stableIDClause: String
        if let trimmedStable {
            stableIDClause = """
            if (id of terminalRef as text) is "\(AppleScriptHelpers.escape(trimmedStable))" then
                select tab tabRef
                activate window w
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end if
            """
        } else {
            stableIDClause = ""
        }

        let workingDirectoryClause: String
        if trimmedStable == nil {
            workingDirectoryClause = """
            set workingDirText to (working directory of terminalRef as text)
            if my normalizePath(workingDirText) is in targetPaths then
                select tab tabRef
                activate window w
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end if
            """
        } else {
            workingDirectoryClause = ""
        }

        let tabFocusClause: String
        if trimmedStable == nil, let trimmedWindow, let trimmedTab {
            tabFocusClause = """
            try
                set targetWindow to first window whose id is "\(AppleScriptHelpers.escape(trimmedWindow))"
                set targetTab to first tab of targetWindow whose id is "\(AppleScriptHelpers.escape(trimmedTab))"
                activate targetWindow
                set terminalRef to focused terminal of targetTab
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end try
            """
        } else if trimmedStable == nil, trimmedPath == nil, let trimmedWindow {
            tabFocusClause = """
            try
                activate (first window whose id is "\(AppleScriptHelpers.escape(trimmedWindow))")
                return "ok|"
            end try
            """
        } else {
            tabFocusClause = ""
        }

        return """
        set targetPaths to \(AppleScriptHelpers.pathListLiteral(projectPath))
        tell application id "com.mitchellh.ghostty"
            activate
            repeat with w in windows
                repeat with tabRef in tabs of w
                    repeat with terminalRef in terminals of tabRef
                        try
                            \(stableIDClause)
                            \(workingDirectoryClause)
                        end try
                    end repeat
                end repeat
            end repeat
            \(tabFocusClause)
        end tell
        return "miss"

        on normalizePath(rawValue)
            set valueText to rawValue as text
            if valueText starts with "file://" then
                set valueText to text 8 thru -1 of valueText
            end if
            set valueText to my decodeURLText(valueText)
            if valueText ends with "/" and valueText is not "/" then
                set valueText to text 1 thru -2 of valueText
            end if
            return valueText
        end normalizePath

        on decodeURLText(valueText)
            set decodedText to valueText
            set decodedText to my replaceText("%20", " ", decodedText)
            set decodedText to my replaceText("%2D", "-", decodedText)
            set decodedText to my replaceText("%2E", ".", decodedText)
            set decodedText to my replaceText("%2F", "/", decodedText)
            set decodedText to my replaceText("%5F", "_", decodedText)
            return decodedText
        end decodeURLText

        on replaceText(findText, replaceText, sourceText)
            set AppleScript's text item delimiters to findText
            set textItems to every text item of sourceText
            set AppleScript's text item delimiters to replaceText
            set rebuiltText to textItems as text
            set AppleScript's text item delimiters to ""
            return rebuiltText
        end replaceText
        """
    }

    /// Override the default `parseFocusOutput` to extract the
    /// resolved-stableID round-trip (`"ok|<stableID>"`) Ghostty's
    /// focus script returns. Apple Terminal / iTerm2 keep the
    /// default `output == "ok"` parser.
    func parseFocusOutput(_ output: String) -> AppleScriptFocusResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ok") else { return .failure }
        let parts = trimmed.split(separator: "|", maxSplits: 1).map(String.init)
        let stableID = parts.count == 2 ? parts[1].nilIfEmpty : nil
        return .success(resolvedStableID: stableID)
    }
}

extension GhosttyTerminalCapability: TerminalAppleScriptContainsProbing {
    func containsSessionScript(
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> String? {
        let trimmedWindow = terminalWindowID?.nilIfEmpty
        let trimmedTab = terminalTabID?.nilIfEmpty
        let trimmedStable = stableTerminalID?.nilIfEmpty
        let trimmedPath = projectPath?.nilIfEmpty

        let hasExplicitLocator = trimmedWindow != nil || trimmedTab != nil || trimmedStable != nil
        guard hasExplicitLocator || trimmedPath != nil else { return nil }

        let windowClause: String
        if let trimmedWindow, let trimmedTab {
            windowClause = """
            try
                set targetWindow to first window whose id is "\(AppleScriptHelpers.escape(trimmedWindow))"
                set targetTab to first tab of targetWindow whose id is "\(AppleScriptHelpers.escape(trimmedTab))"
                return "ok"
            end try
            """
        } else if let trimmedWindow {
            windowClause = """
            try
                if exists (first window whose id is "\(AppleScriptHelpers.escape(trimmedWindow))") then return "ok"
            end try
            """
        } else {
            windowClause = ""
        }

        let stableIDClause: String
        if let trimmedStable {
            stableIDClause = """
            if (id of terminalRef as text) is "\(AppleScriptHelpers.escape(trimmedStable))" then return "ok"
            """
        } else {
            stableIDClause = ""
        }

        return """
        set targetPaths to \(AppleScriptHelpers.pathListLiteral(projectPath))
        tell application id "com.mitchellh.ghostty"
            \(windowClause)
            repeat with w in windows
                repeat with tabRef in tabs of w
                    repeat with terminalRef in terminals of tabRef
                        try
                            \(stableIDClause)
                            set workingDirText to (working directory of terminalRef as text)
                            if my normalizePath(workingDirText) is in targetPaths then return "ok"
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"

        on normalizePath(rawValue)
            set valueText to rawValue as text
            if valueText starts with "file://" then
                set valueText to text 8 thru -1 of valueText
            end if
            set valueText to my decodeURLText(valueText)
            if valueText ends with "/" and valueText is not "/" then
                set valueText to text 1 thru -2 of valueText
            end if
            return valueText
        end normalizePath

        on decodeURLText(valueText)
            set decodedText to valueText
            set decodedText to my replaceText("%20", " ", decodedText)
            set decodedText to my replaceText("%2D", "-", decodedText)
            set decodedText to my replaceText("%2E", ".", decodedText)
            set decodedText to my replaceText("%2F", "/", decodedText)
            set decodedText to my replaceText("%5F", "_", decodedText)
            return decodedText
        end decodeURLText

        on replaceText(findText, replaceText, sourceText)
            set AppleScript's text item delimiters to findText
            set textItems to every text item of sourceText
            set AppleScript's text item delimiters to replaceText
            set rebuiltText to textItems as text
            set AppleScript's text item delimiters to ""
            return rebuiltText
        end replaceText
        """
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
