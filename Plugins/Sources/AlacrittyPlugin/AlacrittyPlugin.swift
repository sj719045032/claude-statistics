import AppKit
import ClaudeStatisticsKit
import Foundation

/// Alacritty terminal plugin (extracted from main binary in M2).
///
/// Alacritty is GPU-rendered with no AppleScript surface; we drive it
/// via its own `alacritty msg` IPC when there's a live alacritty
/// process, falling back to spawning a fresh `--working-directory`
/// invocation when there isn't. Focus return uses the host's
/// `.accessibility` route handler keyed by bundle id (matching what
/// the in-binary capability used before extraction).
@objc(AlacrittyPlugin)
public final class AlacrittyPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "org.alacritty",
        kind: .terminal,
        displayName: "Alacritty",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [],
        principalClass: "AlacrittyPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "Alacritty",
        displayName: "Alacritty",
        category: .terminal,
        bundleIdentifiers: ["org.alacritty", "io.alacritty"],
        terminalNameAliases: ["alacritty"],
        processNameHints: ["alacritty"],
        focusPrecision: .appOnly,
        autoLaunchPriority: 60
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        descriptor.bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        } || FileManager.default.fileExists(atPath: "/Applications/Alacritty.app")
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        AlacrittyLauncher(bundleIdentifiers: Array(descriptor.bundleIdentifiers))
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        AlacrittyReadinessProvider(
            isInstalled: { self.detectInstalled() },
            bundleIdentifiers: Array(descriptor.bundleIdentifiers)
        )
    }
}

private struct AlacrittyLauncher: TerminalLauncher {
    let bundleIdentifiers: [String]
    private let bin = "/Applications/Alacritty.app/Contents/MacOS/alacritty"

    func launch(_ request: TerminalLaunchRequest) {
        // If Alacritty is already running, spawn the new window inside that
        // process via `alacritty msg create-window`. Combined with macOS's
        // "Prefer tabs when opening documents" setting (System Settings →
        // Desktop & Dock), this becomes a new tab on the existing window
        // instead of a separate floating window.
        let msgStatus = runAndWait(executable: bin, arguments: [
            "msg", "create-window",
            "--working-directory", request.cwd,
            "-e", "bash", "-c", request.commandOnly + "; exec bash"
        ])
        if msgStatus == 0 {
            activateApp()
            return
        }

        // No live IPC socket — start a fresh Alacritty process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "--working-directory", request.cwd,
            "-e", "bash", "-c", request.commandOnly + "; exec bash"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        activateApp()
    }

    private func runAndWait(executable: String, arguments: [String]) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func activateApp() {
        guard let bundleId = bundleIdentifiers.first(where: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }),
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

private struct AlacrittyReadinessProvider: TerminalReadinessProviding {
    let isInstalled: () -> Bool
    let bundleIdentifiers: [String]

    func installationStatus() -> TerminalInstallationStatus {
        isInstalled() ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        isInstalled() ? [] : [.appInstalled]
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
                id: "alacritty.open",
                title: "Open Alacritty",
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
