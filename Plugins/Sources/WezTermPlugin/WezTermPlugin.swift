import AppKit
import ClaudeStatisticsKit
import Foundation

/// WezTerm terminal plugin (extracted from main binary in M2).
///
/// WezTerm focuses & launches via its `wezterm cli` mux protocol —
/// `wezterm cli list --format json` enumerates panes, `wezterm cli
/// activate-pane --pane-id <n>` focuses one. The plugin self-contains
/// the JSON shape, the CLI runner, and the socket-discovery logic
/// (`~/.local/share/wezterm/default-org.wezfurlong.wezterm` symlink
/// pointing at the running mux's `gui-sock-<pid>`).
@objc(WezTermPlugin)
public final class WezTermPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.github.wez.wezterm",
        kind: .terminal,
        displayName: "WezTerm",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "WezTermPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "WezTerm",
        displayName: "WezTerm",
        category: .terminal,
        bundleIdentifiers: ["com.github.wez.wezterm"],
        terminalNameAliases: ["wezterm", "wezterm-gui"],
        processNameHints: ["wezterm"],
        focusPrecision: .exact,
        autoLaunchPriority: 20
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        WezTermCLIRunner.commandPath() != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        WezTermFocusStrategy()
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        WezTermLauncher()
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        WezTermReadinessProvider()
    }
}

// MARK: - Launcher

private struct WezTermLauncher: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        guard let wezterm = WezTermCLIRunner.commandPath() else { return }
        let shellEnv = ProcessInfo.processInfo.environment["SHELL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = (shellEnv?.isEmpty == false ? shellEnv! : nil) ?? "/bin/zsh"
        let shellCommand = request.commandOnly + "; exec -l " + TerminalShellCommand.escape(shell)

        // If a WezTerm mux is already running (GUI or headless), spawn
        // the command as a new tab in an existing window rather than
        // opening a fresh window. Detect "mux is reachable" with `cli
        // list` since it's the lightest command that requires a live
        // mux.
        let hasLiveMux = WezTermCLIRunner.run(
            wezterm: wezterm,
            arguments: ["cli", "list", "--format", "json"],
            terminalSocket: nil
        ) != nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wezterm)
        if hasLiveMux {
            process.arguments = [
                "cli", "spawn",
                "--cwd", request.cwd,
                "--",
                shell, "-lc", shellCommand
            ]
        } else {
            process.arguments = [
                "start",
                "--cwd", request.cwd,
                "--",
                shell, "-lc", shellCommand
            ]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()

        // `wezterm start` / `cli spawn` don't bring the app forward
        // on macOS (unlike e.g. kitty `--single-instance`). Without
        // this the launched tab sits behind whatever had focus.
        activateApp()
    }

    private func activateApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.wez.wezterm") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

// MARK: - Focus strategy

private struct WezTermFocusStrategy: TerminalFocusStrategy {
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        let hasLocator = target.tty != nil
            || target.projectPath != nil
            || target.terminalStableID != nil
            || target.terminalTabID != nil
            || target.terminalWindowID != nil
        return hasLocator ? .ready : .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        guard focusViaCLI(target: target) else { return nil }
        return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: target.terminalStableID)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        // CLI is already the most precise locator we have; if it
        // missed, the host runs its activate-app fallback.
        await directFocus(target: target)
    }

    private func focusViaCLI(target: TerminalFocusTarget) -> Bool {
        guard let wezterm = WezTermCLIRunner.commandPath() else { return false }

        if let stableTerminalID = target.terminalStableID?.nilIfEmpty,
           WezTermCLIRunner.run(
                wezterm: wezterm,
                arguments: ["cli", "activate-pane", "--pane-id", stableTerminalID],
                terminalSocket: target.terminalSocket
           ) != nil {
            return true
        }

        guard let output = WezTermCLIRunner.run(
                wezterm: wezterm,
                arguments: ["cli", "list", "--format", "json"],
                terminalSocket: target.terminalSocket
              ),
              let data = output.data(using: .utf8),
              let panes = try? JSONDecoder().decode([WezTermPane].self, from: data)
        else {
            return false
        }

        let variants = target.tty.map(WezTermCLIRunner.ttyVariants) ?? []
        let targetPath = WezTermCLIRunner.normalizedPath(target.projectPath)
        guard let pane = panes.first(where: { pane in
            variants.contains(pane.ttyName ?? "")
                || (targetPath != nil && targetPath == WezTermCLIRunner.normalizedPath(pane.cwd))
        }) else {
            return false
        }

        return WezTermCLIRunner.run(
            wezterm: wezterm,
            arguments: ["cli", "activate-pane", "--pane-id", "\(pane.paneId)"],
            terminalSocket: target.terminalSocket
        ) != nil
    }
}

// MARK: - Readiness

private struct WezTermReadinessProvider: TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus {
        WezTermCLIRunner.commandPath() != nil ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        WezTermCLIRunner.commandPath() != nil ? [] : [.cliAvailable(name: "wezterm")]
    }

    func setupActions() -> [TerminalSetupAction] {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.wez.wezterm") else {
            return []
        }
        return [
            TerminalSetupAction(
                id: "wezterm.open",
                title: "Open WezTerm",
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

// MARK: - CLI runner

private enum WezTermCLIRunner {
    static func commandPath() -> String? {
        if let found = which("wezterm") { return found }
        let candidates = [
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run `wezterm <args>`; returns stdout on `terminationStatus ==
    /// 0`, nil otherwise. Auto-discovers the running mux's socket via
    /// `~/.local/share/wezterm/default-org.wezfurlong.wezterm`
    /// symlink (or the newest `gui-sock-*` file) and threads it
    /// through `WEZTERM_UNIX_SOCKET` so commands hit the live mux
    /// instead of starting a fresh headless one.
    static func run(
        wezterm: String,
        arguments: [String],
        terminalSocket: String?
    ) -> String? {
        let envSocket = resolvedSocketPath(from: terminalSocket) ?? resolvedDefaultSocketPath()
        let environment: [String: String] = envSocket.map { ["WEZTERM_UNIX_SOCKET": $0] } ?? [:]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wezterm)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: stdoutData, encoding: .utf8)
    }

    static func ttyVariants(_ tty: String) -> Set<String> {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        return [tty, trimmed, "/dev/\(trimmed)"]
    }

    static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfEmpty else { return nil }
        var resolved = (path as NSString).expandingTildeInPath
        if resolved.hasPrefix("file://"), let url = URL(string: resolved) {
            resolved = url.path
        }
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    private static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
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
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func resolvedSocketPath(from terminalSocket: String?) -> String? {
        guard let terminalSocket = terminalSocket?.nilIfEmpty else { return nil }
        return FileManager.default.fileExists(atPath: terminalSocket) ? terminalSocket : nil
    }

    private static func resolvedDefaultSocketPath() -> String? {
        let shareDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/wezterm")

        let defaultLink = shareDirectory.appendingPathComponent("default-org.wezfurlong.wezterm")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: defaultLink.path) {
            let resolved = (destination as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }

        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: shareDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return candidates
            .filter { $0.lastPathComponent.hasPrefix("gui-sock-") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
            .first?
            .path
    }
}

// MARK: - wezterm cli list JSON shape

private struct WezTermPane: Decodable {
    let paneId: Int
    let ttyName: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case ttyName = "tty_name"
        case cwd
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
