import AppKit
import ClaudeStatisticsKit
import Foundation

struct AlacrittyTerminalCapability: TerminalCapability, TerminalLaunching, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.alacrittyOptionID
    let category: TerminalCapabilityCategory = .terminal
    let displayName = "Alacritty"
    let bundleIdentifiers: Set<String> = ["org.alacritty", "io.alacritty"]
    let terminalNameAliases: Set<String> = ["alacritty"]
    let processNameHints: Set<String> = ["alacritty"]
    let route: TerminalFocusRoute = .accessibility
    let autoLaunchPriority: Int? = 60

    var isInstalled: Bool {
        bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        } || FileManager.default.fileExists(atPath: "/Applications/Alacritty.app")
    }

    func launch(_ request: TerminalLaunchRequest) {
        let bin = "/Applications/Alacritty.app/Contents/MacOS/alacritty"

        // If Alacritty is already running, spawn the new window inside that
        // process via `alacritty msg create-window`. Combined with macOS's
        // "Prefer tabs when opening documents" setting (System Settings →
        // Desktop & Dock), this becomes a new tab on the existing window
        // instead of a separate floating window.
        let msgResult = TerminalProcessRunner.run(executable: bin, arguments: [
            "msg", "create-window",
            "--working-directory", request.cwd,
            "-e", "bash", "-c", request.commandOnly + "; exec bash"
        ])
        if msgResult?.terminationStatus == 0 {
            activateAlacrittyApp()
            return
        }

        // No live IPC socket — start a fresh Alacritty process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "--working-directory", request.cwd,
            "-e", "bash", "-c", request.commandOnly + "; exec bash"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        activateAlacrittyApp()
    }

    private func activateAlacrittyApp() {
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

    func installationStatus() -> TerminalInstallationStatus {
        installedStatus
    }

    func setupRequirements() -> [TerminalRequirement] {
        defaultInstallationRequirements()
    }

    func setupActions() -> [TerminalSetupAction] {
        [openPrimaryAppAction(id: "alacritty.open", title: "Open Alacritty")].compactMap { $0 }
    }
}
