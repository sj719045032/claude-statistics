import AppKit
import ClaudeStatisticsKit
import Foundation

/// Warp terminal plugin (extracted from main binary in M2).
///
/// Warp's automation surface is closed (no CLI / AppleScript focus
/// API), so launch goes through the same NSWorkspace.shared.open
/// `.cs-launch` script bootstrap Ghostty uses, and focus return
/// falls back to the host's `.accessibility` route handler keyed by
/// `bundleIdentifiers` (which the descriptor exposes back through
/// `PluginBackedTerminalCapability`).
@objc(WarpPlugin)
public final class WarpPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "dev.warp.Warp-Stable",
        kind: .terminal,
        displayName: "Warp",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "WarpPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "Warp",
        displayName: "Warp",
        category: .terminal,
        bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        terminalNameAliases: ["warp", "warpstabl", "warpterminal"],
        processNameHints: ["warp"],
        focusPrecision: .appOnly,
        autoLaunchPriority: 50
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        descriptor.bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        WarpLauncher()
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        WarpReadinessProvider(
            bundleIdentifiers: Array(descriptor.bundleIdentifiers),
            displayName: descriptor.displayName
        )
    }
}

private struct WarpLauncher: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        // Warp has no CLI / AppleScript automation, so we rely on
        // NSWorkspace.shared.open dropping a `.cs-launch` shim into
        // the project directory: macOS hands the file to Warp via
        // an open-doc Apple Event, Warp opens a tab whose cwd is the
        // file's parent (i.e. the project root we want), and the
        // shim self-deletes after exec'ing the requested command.
        // Writing the shim anywhere outside `request.cwd` would land
        // the user in `~/.claude-statistics/run` instead of their
        // project — matching the same constraint Ghostty's launch
        // path documents.
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
}

private struct WarpReadinessProvider: TerminalReadinessProviding {
    let bundleIdentifiers: [String]
    let displayName: String

    private var isInstalled: Bool {
        bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    func installationStatus() -> TerminalInstallationStatus {
        isInstalled ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        isInstalled ? [] : [.appInstalled]
    }

    func setupActions() -> [TerminalSetupAction] {
        guard let bundleId = bundleIdentifiers.first(where: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }),
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return []
        }
        return [
            TerminalSetupAction(
                id: "warp.open",
                title: "Open Warp",
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
