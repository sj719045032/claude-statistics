import AppKit
import ClaudeStatisticsKit
import Foundation

/// Cursor editor plugin — VSCode fork, single bundle identifier.
/// See VSCodePlugin doc-comment for the per-vendor rationale.
@objc(CursorPlugin)
public final class CursorPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.todesktop.230313mzl4w4u92",
        kind: .terminal,
        displayName: "Cursor",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "CursorPlugin",
        category: PluginCatalogCategory.editorIntegration
    )

    public let descriptor = TerminalDescriptor(
        id: "com.todesktop.230313mzl4w4u92",
        displayName: "Cursor",
        category: .editor,
        bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
        terminalNameAliases: ["cursor"],
        processNameHints: ["cursor"],
        focusPrecision: .appOnly,
        autoLaunchPriority: nil
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifiers.first!) != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        ActivateAppFocusStrategy(bundleIdentifiers: Array(descriptor.bundleIdentifiers))
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        OpenInEditorLauncher(bundleIdentifiers: Array(descriptor.bundleIdentifiers))
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        EditorReadinessProvider(
            bundleIdentifiers: Array(descriptor.bundleIdentifiers),
            displayName: "Cursor",
            actionID: "cursor.open"
        )
    }
}
