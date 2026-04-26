import AppKit
import ClaudeStatisticsKit
import Foundation

/// Zed editor plugin.
@objc(ZedPlugin)
public final class ZedPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "dev.zed.Zed",
        kind: .terminal,
        displayName: "Zed",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "ZedPlugin",
        category: PluginCatalogCategory.editorIntegration
    )

    public let descriptor = TerminalDescriptor(
        id: "dev.zed.Zed",
        displayName: "Zed",
        category: .editor,
        bundleIdentifiers: ["dev.zed.Zed"],
        terminalNameAliases: ["zed"],
        processNameHints: ["zed"],
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
            displayName: "Zed",
            actionID: "zed.open"
        )
    }
}
