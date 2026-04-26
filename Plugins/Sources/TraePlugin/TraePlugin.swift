import AppKit
import ClaudeStatisticsKit
import Foundation

/// Trae editor plugin (ByteDance's VSCode fork).
@objc(TraePlugin)
public final class TraePlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.trae.app",
        kind: .terminal,
        displayName: "Trae",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "TraePlugin",
        category: PluginCatalogCategory.editorIntegration
    )

    public let descriptor = TerminalDescriptor(
        id: "com.trae.app",
        displayName: "Trae",
        category: .editor,
        bundleIdentifiers: ["com.trae.app"],
        terminalNameAliases: ["trae"],
        processNameHints: ["trae"],
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
            displayName: "Trae",
            actionID: "trae.open"
        )
    }
}
