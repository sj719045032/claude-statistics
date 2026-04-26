import AppKit
import ClaudeStatisticsKit
import Foundation

struct WarpTerminalCapability: TerminalCapability, TerminalLaunching, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.warpOptionID
    let category: TerminalCapabilityCategory = .terminal
    let displayName = "Warp"
    let bundleIdentifiers: Set<String> = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
    let terminalNameAliases: Set<String> = ["warp", "warpstabl", "warpterminal"]
    let processNameHints: Set<String> = ["warp"]
    let route: TerminalFocusRoute = .accessibility
    let autoLaunchPriority: Int? = 50

    var isInstalled: Bool {
        bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    func launch(_ request: TerminalLaunchRequest) {
        // Mirror GhosttyTerminalCapability: the bootstrap script MUST live
        // under request.cwd so the launching terminal uses the project
        // directory as the new tab's working directory. Writing it to
        // ~/.claude-statistics/run leaves the tab in the wrong cwd.
        let expandedCwd = (request.cwd as NSString).expandingTildeInPath
        let scriptPath = (expandedCwd as NSString).appendingPathComponent(".cs-launch")
        let content = """
        #!/bin/bash
        rm -f \(TerminalShellCommand.escape(scriptPath))
        cd \(TerminalShellCommand.escape(expandedCwd)) || exit 1
        exec \(request.commandOnly)
        """
        guard (try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)) != nil
        else { return }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable")
            ?? URL(fileURLWithPath: "/Applications/Warp.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: scriptPath)],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }

    func installationStatus() -> TerminalInstallationStatus {
        installedStatus
    }

    func setupRequirements() -> [TerminalRequirement] {
        defaultInstallationRequirements()
    }

    func setupActions() -> [TerminalSetupAction] {
        [openPrimaryAppAction(id: "warp.open", title: "Open Warp")].compactMap { $0 }
    }
}
