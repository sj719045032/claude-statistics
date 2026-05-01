import AppKit
import ClaudeStatisticsKit
import Foundation

/// Apple Terminal built into the host module (chassis built-in per
/// `docs/PLUGIN_ARCHITECTURE.md` §1.1). Originally extracted to a
/// `.csplugin` in commit `2000110`; reverted in this refactor so all
/// chassis built-ins (Claude provider, share roles/themes, iTerm2 /
/// Ghostty / Apple Terminal) actually live in the host module rather
/// than mixing forms. Behaviour is identical to the previous
/// `.csplugin` — same `@objc(AppleTerminalPlugin)` name + same
/// `id "com.apple.Terminal"` so the manifest layer doesn't see a
/// rename. The class is `internal` (no `public`) because it stays
/// in this module.
@objc(AppleTerminalPlugin)
final class AppleTerminalPlugin: NSObject, TerminalPlugin {
    static let manifest = PluginManifest(
        id: "com.apple.Terminal",
        kind: .terminal,
        displayName: "Terminal",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.appleScript],
        principalClass: "AppleTerminalPlugin",
        category: PluginCatalogCategory.terminal
    )

    let descriptor = TerminalDescriptor(
        id: "Terminal",
        displayName: "Terminal",
        category: .terminal,
        bundleIdentifiers: ["com.apple.Terminal"],
        terminalNameAliases: ["apple_terminal", "terminal", "apple terminal"],
        processNameHints: ["terminal"],
        focusPrecision: .exact,
        autoLaunchPriority: 70
    )

    override init() { super.init() }

    func detectInstalled() -> Bool { true } // Terminal.app ships with macOS.

    func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        AppleTerminalFocusStrategy()
    }

    func makeLauncher() -> (any TerminalLauncher)? {
        AppleTerminalLauncher()
    }

    func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        AppleTerminalReadinessProvider()
    }
}

// MARK: - Launcher

private struct AppleTerminalLauncher: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        let command = TerminalShellCommand.escapeAppleScript(request.commandInWorkingDirectory)
        // `do script X in window N` opens a new *tab* in that window;
        // plain `do script X` opens a fresh window. Prefer the tab
        // form when one already exists so users don't accumulate
        // windows.
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
        AppleTerminalScriptRunner.fireAndForget(script)
    }
}

// MARK: - Focus strategy

private struct AppleTerminalFocusStrategy: TerminalFocusStrategy {
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        // Apple Terminal can land on the exact tab when we have a tty
        // identifier; without one, only app-level activation.
        target.tty?.isEmpty == false ? .ready : .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        guard let tty = target.tty, !tty.isEmpty else { return nil }
        let script = """
        set targetTtys to \(AppleTerminalScriptRunner.ttyListLiteral(tty))
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if targetTtys contains (tty of t as text) then
                            set selected of t to true
                            set frontmost of w to true
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return "miss"
        """
        guard let output = AppleTerminalScriptRunner.run(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        else {
            return nil
        }
        return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: target.terminalStableID)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        // No richer fallback for Apple Terminal — the directFocus
        // script is already the most accurate path. If it missed, the
        // host will run its generic activate-app fallback after.
        await directFocus(target: target)
    }
}

// MARK: - Readiness

private struct AppleTerminalReadinessProvider: TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus { .installed }
    func setupRequirements() -> [TerminalRequirement] { [] }
    func setupActions() -> [TerminalSetupAction] {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return []
        }
        return [
            TerminalSetupAction(
                id: "terminal.open",
                title: "Open Terminal",
                kind: .openApp,
                perform: {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                    return .none
                }
            )
        ]
    }
}

// MARK: - osascript runner

private enum AppleTerminalScriptRunner {
    static func run(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fire-and-forget variant for launch (we don't care about output,
    /// just want the process spawned). Falls back to `NSAppleScript`
    /// if `Process` can't launch — same belt-and-suspenders the host's
    /// previous `TerminalAppleScriptRunner` used.
    static func fireAndForget(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            if let script = NSAppleScript(source: source) {
                var err: NSDictionary?
                script.executeAndReturnError(&err)
            }
        }
    }

    /// AppleScript list literal of accepted tty forms, mirroring the
    /// host-side helper. Apple Terminal sometimes reports tty with the
    /// `/dev/` prefix and sometimes without; this list covers both.
    static func ttyListLiteral(_ tty: String) -> String {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        let values = [tty, trimmed, "/dev/\(trimmed)"]
        let unique = Array(Set(values)).sorted()
        return "{\(unique.map { "\"\(escape($0))\"" }.joined(separator: ", "))}"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
