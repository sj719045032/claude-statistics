import AppKit
import ClaudeStatisticsKit
import Foundation

/// Windsurf editor plugin (Codeium's VSCode fork).
@objc(WindsurfPlugin)
public final class WindsurfPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "com.exafunction.windsurf",
        kind: .terminal,
        displayName: "Windsurf",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "WindsurfPlugin",
        category: PluginCatalogCategory.editorIntegration
    )

    public let descriptor = TerminalDescriptor(
        id: "com.exafunction.windsurf",
        displayName: "Windsurf",
        category: .editor,
        bundleIdentifiers: ["com.exafunction.windsurf"],
        terminalNameAliases: ["windsurf"],
        processNameHints: ["windsurf"],
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
            displayName: "Windsurf",
            actionID: "windsurf.open"
        )
    }
}
