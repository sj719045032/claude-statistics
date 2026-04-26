import AppKit
import ClaudeStatisticsKit
import Foundation

/// Legacy umbrella editor capability — fully drained of per-vendor
/// metadata now that VSCode / Cursor / Windsurf / Trae / Zed each
/// ship as their own `.csplugin`. Kept temporarily so the existing
/// "Editor" Settings UI option (`TerminalPreferences.editorOptionID`)
/// keeps launching `EditorApp.preferred` until Phase A.6 replaces
/// that umbrella choice with five distinct entries — one per plugin.
/// At that point this struct + EditorPlugin wrapper + EditorApp
/// enum + the editorOptionID itself all get deleted together.
///
/// Empty `bundleIdentifiers` / `terminalNameAliases` /
/// `processNameHints` mean ProcessTreeWalker + bundleId-aware
/// dispatch never land here; those paths now resolve through the
/// per-vendor plugins instead.
struct EditorTerminalCapability: TerminalCapability, TerminalLauncher, TerminalReadinessProviding {
    let optionID: String? = TerminalPreferences.editorOptionID
    let category: TerminalCapabilityCategory = .editor
    let displayName = "Editor"
    let bundleIdentifiers: Set<String> = []
    let terminalNameAliases: Set<String> = []
    let processNameHints: Set<String> = []
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
