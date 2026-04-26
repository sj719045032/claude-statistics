import AppKit
import ClaudeStatisticsKit
import Foundation

struct WezTermTerminalCapability: TerminalCapability, TerminalLaunching, TerminalFocusing, TerminalFocusCapabilityProviding, TerminalDirectFocusing, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.wezTermOptionID
    let category: TerminalCapabilityCategory = .terminal
    let displayName = "WezTerm"
    let bundleIdentifiers: Set<String> = ["com.github.wez.wezterm"]
    let terminalNameAliases: Set<String> = ["wezterm", "wezterm-gui"]
    let processNameHints: Set<String> = ["wezterm"]
    let route: TerminalFocusRoute = .cli(.wezterm)
    let tabFocusPrecision: TerminalTabFocusPrecision = .exact
    let autoLaunchPriority: Int? = 20

    var isInstalled: Bool {
        TerminalCLICommand.commandPath("wezterm") != nil
    }

    func launch(_ request: TerminalLaunchRequest) {
        guard let wezterm = TerminalCLICommand.commandPath("wezterm") else { return }
        let shellEnv = Foundation.ProcessInfo.processInfo.environment["SHELL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = (shellEnv?.isEmpty == false ? shellEnv! : nil) ?? "/bin/zsh"
        let shellCommand = request.commandOnly + "; exec -l " + TerminalShellCommand.escape(shell)

        // If a WezTerm mux is already running (GUI or headless), spawn the
        // command as a new tab in an existing window rather than opening a
        // fresh window. Detect "mux is reachable" with `cli list` since it's
        // the lightest command that requires a live mux.
        let hasLiveMux = runCLI(
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

        // `wezterm start` / `cli spawn` don't bring the app forward on macOS
        // (unlike e.g. kitty `--single-instance`). Without this the launched
        // tab sits behind whatever had focus.
        activateWezTermApp()
    }

    private func activateWezTermApp() {
        guard let bundleId = bundleIdentifiers.first(where: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }),
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    func contains(_ target: TerminalFocusTarget) -> Bool {
        guard let output = runCLI(arguments: ["cli", "list", "--format", "json"], terminalSocket: target.terminalSocket),
              let data = output.data(using: .utf8),
              let panes = try? JSONDecoder().decode([WezTermPane].self, from: data)
        else {
            return false
        }

        if let stableTerminalID = target.terminalStableID?.nilIfEmpty,
           panes.contains(where: { "\($0.paneId)" == stableTerminalID }) {
            return true
        }

        let variants = target.tty.map(TerminalCLICommand.ttyVariants) ?? []
        let targetPath = TerminalCLICommand.normalizedPath(target.projectPath)
        return panes.contains { pane in
            (!variants.isEmpty && variants.contains(pane.ttyName ?? ""))
                || (targetPath != nil && targetPath == TerminalCLICommand.normalizedPath(pane.cwd))
        }
    }

    func focus(_ target: TerminalFocusTarget) -> Bool {
        if let stableTerminalID = target.terminalStableID?.nilIfEmpty,
           runCLI(
                arguments: ["cli", "activate-pane", "--pane-id", stableTerminalID],
                terminalSocket: target.terminalSocket,
                label: "wezterm activate-pane stable"
           ) != nil {
            return true
        }

        guard let output = runCLI(
                arguments: ["cli", "list", "--format", "json"],
                terminalSocket: target.terminalSocket,
                label: "wezterm list"
              ),
              let data = output.data(using: .utf8),
              let panes = try? JSONDecoder().decode([WezTermPane].self, from: data)
        else {
            return false
        }

        let variants = target.tty.map(TerminalCLICommand.ttyVariants) ?? []
        let targetPath = TerminalCLICommand.normalizedPath(target.projectPath)
        guard let pane = panes.first(where: { pane in
            variants.contains(pane.ttyName ?? "")
                || (targetPath != nil && targetPath == TerminalCLICommand.normalizedPath(pane.cwd))
        }) else {
            return false
        }

        return runCLI(
            arguments: ["cli", "activate-pane", "--pane-id", "\(pane.paneId)"],
            terminalSocket: target.terminalSocket,
            label: "wezterm activate-pane fallback"
        ) != nil
    }

    func focusCapability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        let hasLocator = target.tty != nil
            || target.projectPath != nil
            || target.terminalStableID != nil
            || target.terminalTabID != nil
            || target.terminalWindowID != nil
        return hasLocator ? .ready : .appOnly
    }

    func directFocus(_ target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        guard focus(target) else { return nil }
        _ = await MainActor.run {
            ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: nil)
        }
        return TerminalFocusExecutionResult(
            capability: .ready,
            resolvedStableID: target.terminalStableID
        )
    }

    func installationStatus() -> TerminalInstallationStatus {
        installedStatus
    }

    func setupRequirements() -> [TerminalRequirement] {
        isInstalled ? [] : [.cliAvailable(name: "wezterm")]
    }

    func setupActions() -> [TerminalSetupAction] {
        [openPrimaryAppAction(id: "wezterm.open", title: "Open WezTerm")].compactMap { $0 }
    }

    private func runCLI(
        arguments: [String],
        terminalSocket: String?,
        label: String? = nil
    ) -> String? {
        guard let wezterm = TerminalCLICommand.commandPath("wezterm") else { return nil }

        let envSocket = resolvedSocketPath(from: terminalSocket) ?? resolvedDefaultSocketPath()
        if let envSocket {
            DiagnosticLogger.shared.info("WezTerm CLI using socket \(envSocket)")
        } else {
            DiagnosticLogger.shared.warning("WezTerm CLI proceeding without explicit socket")
        }

        let result = TerminalProcessRunner.run(
            executable: wezterm,
            arguments: arguments,
            environment: envSocket.map { ["WEZTERM_UNIX_SOCKET": $0] }
        )
        guard let result else {
            if let label {
                DiagnosticLogger.shared.warning("\(label) failed stderr=process did not launch")
            }
            return nil
        }
        guard result.terminationStatus == 0 else {
            if let label {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = stderr.isEmpty ? stdout : stderr
                DiagnosticLogger.shared.warning("\(label) failed stderr=\(message.prefix(300))")
            }
            return nil
        }
        return result.stdout
    }

    private func resolvedSocketPath(from terminalSocket: String?) -> String? {
        guard let terminalSocket = terminalSocket?.nilIfEmpty else { return nil }
        if FileManager.default.fileExists(atPath: terminalSocket) {
            return terminalSocket
        }
        return nil
    }

    private func resolvedDefaultSocketPath() -> String? {
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
