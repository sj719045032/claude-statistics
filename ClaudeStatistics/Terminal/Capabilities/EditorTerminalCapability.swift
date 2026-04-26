import AppKit
import ClaudeStatisticsKit
import Foundation

/// Legacy umbrella editor capability. Per-vendor editor plugins
/// (VSCodePlugin already extracted; Cursor / Windsurf / Trae / Zed
/// follow) own VSCode + Insiders themselves; once all five are
/// extracted this whole struct + the EditorPlugin wrapper +
/// EditorApp + the TerminalPreferences.editorOptionID seam can be
/// deleted in one go.
struct EditorTerminalCapability: TerminalCapability, TerminalLauncher, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.editorOptionID
    let category: TerminalCapabilityCategory = .editor
    let displayName = "Editor"
    let bundleIdentifiers: Set<String> = [
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "com.trae.app",
        "dev.zed.Zed"
    ]
    let terminalNameAliases: Set<String> = [
        "cursor", "windsurf", "trae", "zed"
    ]
    let processNameHints: Set<String> = [
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
