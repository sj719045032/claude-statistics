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
/// Behaviour matches the previous in-host implementation, now
/// delegated to the shared SDK helpers (`ActivateAppFocusStrategy` /
/// `OpenInEditorLauncher` / `EditorReadinessProvider`) so the plugin
/// stays a thin descriptor + factory wrapper.
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

    /// Stable bundle id list (sorted) so the SDK helpers see VSCode
    /// stable preferred over Insiders when both are installed.
    private var bundleIDs: [String] {
        ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
    }

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        ActivateAppFocusStrategy(bundleIdentifiers: bundleIDs)
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        OpenInEditorLauncher(bundleIdentifiers: bundleIDs)
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        EditorReadinessProvider(
            bundleIdentifiers: bundleIDs,
            displayName: "VSCode",
            actionID: "vscode.open"
        )
    }
}
