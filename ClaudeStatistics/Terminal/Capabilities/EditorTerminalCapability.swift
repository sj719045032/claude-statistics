import AppKit
import ClaudeStatisticsKit
import Foundation

struct EditorTerminalCapability: TerminalCapability, TerminalLaunching, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.editorOptionID
    let category: TerminalCapabilityCategory = .editor
    let displayName = "Editor"
    let bundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "com.trae.app",
        "dev.zed.Zed"
    ]
    let terminalNameAliases: Set<String> = [
        "vscode", "visual studio code", "code",
        "vscode-insiders", "code-insiders",
        "cursor", "windsurf", "trae", "zed"
    ]
    let processNameHints: Set<String> = [
        "visual studio code",
        "code - insiders",
        "code-insiders",
        "cursor",
        "windsurf",
        "trae",
        "zed"
    ]
    let route: TerminalFocusRoute = .activate

    var isInstalled: Bool { EditorApp.preferred.isInstalled }

    func launch(_ request: TerminalLaunchRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.commandInWorkingDirectory, forType: .string)

        guard let editorURL = EditorApp.preferred.appURL else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: request.cwd)],
            withApplicationAt: editorURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func installationStatus() -> TerminalInstallationStatus {
        installedStatus
    }

    func setupRequirements() -> [TerminalRequirement] {
        isInstalled ? [] : [.appInstalled]
    }

    func setupActions() -> [TerminalSetupAction] {
        if let appURL = EditorApp.preferred.appURL {
            return [
                TerminalSetupAction(
                    id: "editor.open",
                    title: "Open \(EditorApp.preferred.rawValue)",
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
        return []
    }
}
