import AppKit
import ClaudeStatisticsKit
import Foundation

/// First editor-integration plugin extracted from the bundled
/// `EditorTerminalCapability` aggregate. Owns Visual Studio Code +
/// VSCode Insiders.
///
/// Why this is its own `.csplugin` instead of staying part of an
/// "Editor" umbrella: marketplace is per-vendor — a user who only
/// uses VSCode shouldn't pull in Cursor / Windsurf / Trae / Zed
/// support, and an upstream VSCode change shouldn't force a rev to
/// every other editor plugin.
///
/// Behaviour matches the previous in-host implementation:
/// - "Focus" = activate the running app (no per-window deep link;
///    VSCode doesn't expose one for hook-launched terminals).
/// - "Launch new session" = copy the CLI command to the clipboard,
///    then `open <cwd>` in VSCode so the integrated terminal opens
///    in the project root and the user can paste with ⌘V.
@objc(VSCodePlugin)
public final class VSCodePlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.microsoft.VSCode",
        kind: .terminal,
        displayName: "VSCode",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "VSCodePlugin",
        category: PluginCatalogCategory.editorIntegration
    )

    public let descriptor = TerminalDescriptor(
        id: "com.microsoft.VSCode",
        displayName: "VSCode",
        category: .editor,
        bundleIdentifiers: [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders"
        ],
        terminalNameAliases: [
            "vscode", "visual studio code", "code",
            "vscode-insiders", "code-insiders"
        ],
        processNameHints: [
            "visual studio code",
            "code - insiders",
            "code-insiders"
        ],
        focusPrecision: .appOnly,
        autoLaunchPriority: nil
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        for bundleId in descriptor.bundleIdentifiers {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
                return true
            }
        }
        return false
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        VSCodeFocusStrategy()
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        VSCodeLauncher()
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        VSCodeReadiness()
    }
}

/// Same as the legacy `ActivateTerminalFocusRouteHandler` but reduced
/// to "activate by bundle id" — VSCode has no AppleScript / CLI focus
/// surface, so we just bring the app forward.
struct VSCodeFocusStrategy: TerminalFocusStrategy {
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        nil
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        let activated = await MainActor.run { activate(bundleId: target.bundleId) }
        return activated
            ? TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
            : nil
    }

    @MainActor
    private func activate(bundleId: String?) -> Bool {
        let candidates: [String]
        if let bundleId {
            candidates = [bundleId]
        } else {
            candidates = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        }
        for candidate in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first,
               app.activate(options: [.activateAllWindows]) {
                return true
            }
        }
        for candidate in candidates {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) else {
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        }
        return false
    }
}

/// Copy the CLI command to the clipboard and open the working
/// directory in VSCode, mirroring the previous in-host launcher.
struct VSCodeLauncher: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.commandInWorkingDirectory, forType: .string)

        // Prefer stable VSCode; fall back to Insiders if only that is
        // installed.
        let bundleIDs = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        guard let appURL = bundleIDs
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else { return }

        NSWorkspace.shared.open(
            [URL(fileURLWithPath: request.cwd)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

struct VSCodeReadiness: TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus {
        let installed = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
            .contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return installed ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        installationStatus() == .installed ? [] : [.appInstalled]
    }

    func setupActions() -> [TerminalSetupAction] {
        guard let appURL = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else { return [] }

        return [
            TerminalSetupAction(
                id: "vscode.open",
                title: "Open VSCode",
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
