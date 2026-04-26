import AppKit
import ClaudeStatisticsKit
import Foundation

struct KittyTerminalCapability: TerminalCapability, TerminalLauncher, TerminalFocusing, TerminalFocusCapabilityProviding, TerminalDirectFocusing, TerminalSetupProviding, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.kittyOptionID
    let category: TerminalCapabilityCategory = .terminal
    let displayName = "Kitty"
    let bundleIdentifiers: Set<String> = ["net.kovidgoyal.kitty"]
    let terminalNameAliases: Set<String> = ["kitty", "xterm-kitty"]
    let processNameHints: Set<String> = ["kitty"]
    let route: TerminalFocusRoute = .cli(.kitty)
    let tabFocusPrecision: TerminalTabFocusPrecision = .exact
    let autoLaunchPriority: Int? = 40
    let setupTitle = "Kitty"
    let setupActionTitle = "Configure Kitty"
    let setupConfigURL: URL? = KittyFocusSetup.configURL

    var isInstalled: Bool {
        TerminalCLICommand.commandPath("kitty") != nil
    }

    func launch(_ request: TerminalLaunchRequest) {
        guard let kitty = TerminalCLICommand.commandPath("kitty") else { return }

        // If remote-control is configured and a live kitty is running, open a
        // new tab in the current window rather than piling up windows.
        if let socketArgs = KittyFocuser.socketArgs(terminalSocket: nil) {
            let tabArgs = ["@"] + socketArgs + [
                "launch",
                "--type=tab",
                "--cwd", request.cwd,
                "bash", "-c", request.commandOnly + "; exec bash"
            ]
            let result = TerminalProcessRunner.run(executable: kitty, arguments: tabArgs)
            if result?.terminationStatus == 0 {
                activateKittyApp()
                return
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: kitty)
        process.arguments = [
            "--single-instance",
            "--directory", request.cwd,
            "bash", "-c", request.commandOnly + "; exec bash"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        activateKittyApp()
    }

    private func activateKittyApp() {
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
        KittyFocuser.contains(
            tty: target.tty,
            projectPath: target.projectPath,
            terminalSocket: target.terminalSocket,
            terminalWindowID: target.terminalWindowID,
            terminalTabID: target.terminalTabID,
            stableTerminalID: target.terminalStableID
        )
    }

    func focus(_ target: TerminalFocusTarget) -> Bool {
        KittyFocuser.focus(
            tty: target.tty,
            projectPath: target.projectPath,
            terminalSocket: target.terminalSocket,
            terminalWindowID: target.terminalWindowID,
            terminalTabID: target.terminalTabID,
            stableTerminalID: target.terminalStableID
        )
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
        return TerminalFocusExecutionResult(
            capability: .ready,
            resolvedStableID: target.terminalStableID
        )
    }

    func setupStatus() -> TerminalSetupStatus {
        let status = KittyFocusSetup.status()
        let detail = [status.configuredSocket, status.liveSocket]
            .compactMap { $0 }
            .joined(separator: "\nLive: ")
        return TerminalSetupStatus(
            isReady: status.isReady,
            isAvailable: status.kittyInstalled,
            summary: status.summary,
            detail: detail.isEmpty ? nil : "Configured: \(detail)"
        )
    }

    func ensureSetup() throws -> TerminalSetupResult {
        let result = try KittyFocusSetup.ensureConfigured()
        let message: String
        if result.changed {
            if let backupURL = result.backupURL {
                message = "Updated kitty.conf. Backup: \(backupURL.lastPathComponent). Restart Kitty or reopen a Kitty window."
            } else {
                message = "Created kitty.conf. Restart Kitty or reopen a Kitty window."
            }
        } else {
            message = "Kitty config already contains the required settings. If focus still looks unavailable, reopen a Kitty window so the live socket appears."
        }
        return TerminalSetupResult(
            changed: result.changed,
            message: message,
            backupURL: result.backupURL
        )
    }

    func installationStatus() -> TerminalInstallationStatus {
        isInstalled ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        let status = KittyFocusSetup.status()
        guard status.kittyInstalled else {
            return [.cliAvailable(name: "kitty")]
        }

        var requirements: [TerminalRequirement] = []
        if status.configuredSocket == nil {
            requirements.append(.configPatched(file: KittyFocusSetup.configURL.path))
        } else if !status.configuredSocketAlive {
            requirements.append(.appRestartRequired(appName: displayName))
        }
        return requirements
    }

    func setupActions() -> [TerminalSetupAction] {
        guard isInstalled else { return [] }

        var actions: [TerminalSetupAction] = [
            TerminalSetupAction(
                id: "kitty.configure",
                title: "Apply Fix",
                kind: .runAutomaticFix,
                perform: {
                    let result = try ensureSetup()
                    return TerminalSetupActionOutcome(message: result.message)
                }
            )
        ]

        if let configURL = setupConfigURL {
            actions.append(
                TerminalSetupAction(
                    id: "kitty.openConfig",
                    title: "Open Config",
                    kind: .openConfigFile,
                    perform: {
                        NSWorkspace.shared.open(configURL.deletingLastPathComponent())
                        return .none
                    }
                )
            )
        }

        if let bundleId = primaryBundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            actions.append(
                TerminalSetupAction(
                    id: "kitty.openApp",
                    title: "Open Kitty",
                    kind: .openApp,
                    perform: {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                        return .none
                    }
                )
            )
        }

        return actions
    }
}
