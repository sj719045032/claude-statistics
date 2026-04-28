import AppKit
import ClaudeStatisticsKit
import Foundation

/// Kitty terminal plugin (extracted from main binary in M2).
///
/// Kitty has no AppleScript surface — focus & launch ride on its
/// `kitty @` remote-control protocol over a Unix socket. The user
/// has to opt in by adding `allow_remote_control socket-only` and
/// `listen_on unix:/tmp/kitty-<user>` to `~/.config/kitty/kitty.conf`,
/// so the plugin also ships a setup wizard that patches the file
/// idempotently and prompts the user to restart Kitty afterwards.
@objc(KittyPlugin)
public final class KittyPlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(
        id: "net.kovidgoyal.kitty",
        kind: .terminal,
        displayName: "Kitty",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.filesystemHome],
        principalClass: "KittyPlugin"
    )

    public let descriptor = TerminalDescriptor(
        id: "Kitty",
        displayName: "Kitty",
        category: .terminal,
        bundleIdentifiers: ["net.kovidgoyal.kitty"],
        terminalNameAliases: ["kitty", "xterm-kitty"],
        processNameHints: ["kitty"],
        focusPrecision: .exact,
        autoLaunchPriority: 40
    )

    public override init() { super.init() }

    public func detectInstalled() -> Bool {
        KittyCLIRunner.commandPath() != nil
    }

    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? {
        KittyFocusStrategy()
    }

    public func makeLauncher() -> (any TerminalLauncher)? {
        KittyLauncher()
    }

    public func makeReadinessProvider() -> (any TerminalReadinessProviding)? {
        KittyReadinessProvider()
    }

    public func makeSetupWizard() -> (any TerminalSetupProviding)? {
        KittySetupWizard()
    }
}

// MARK: - Launcher

private struct KittyLauncher: TerminalLauncher {
    func launch(_ request: TerminalLaunchRequest) {
        guard let kitty = KittyCLIRunner.commandPath() else { return }

        // If remote-control is configured and a live kitty is running,
        // open a new tab in the current window rather than piling up
        // windows.
        if let socketArgs = KittyConfig.socketArgs(terminalSocket: nil) {
            let tabArgs = ["@"] + socketArgs + [
                "launch",
                "--type=tab",
                "--cwd", request.cwd,
                "bash", "-c", request.commandOnly + "; exec bash"
            ]
            let result = KittyCLIRunner.runWithStatus(executable: kitty, arguments: tabArgs)
            if result?.terminationStatus == 0 {
                activateApp()
                return
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: kitty)
        process.arguments = [
            "--single-instance",
            "--directory", request.cwd,
            "bash", "-c", request.commandOnly + "; exec bash"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        activateApp()
    }

    private func activateApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.kovidgoyal.kitty") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

// MARK: - Focus strategy

private struct KittyFocusStrategy: TerminalFocusStrategy {
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        let hasLocator = target.tty != nil
            || target.projectPath != nil
            || target.terminalStableID != nil
            || target.terminalTabID != nil
            || target.terminalWindowID != nil
        return hasLocator ? .ready : .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        guard focusViaCLI(target: target) else { return nil }
        return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: target.terminalStableID)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        // Same path as direct: the CLI socket protocol is already the
        // most accurate locator we have. If it failed, the host runs
        // its activate-app fallback.
        await directFocus(target: target)
    }

    private func focusViaCLI(target: TerminalFocusTarget) -> Bool {
        guard let kitty = KittyCLIRunner.commandPath() else { return false }
        guard let socketArgs = KittyConfig.socketArgs(terminalSocket: target.terminalSocket) else {
            return false
        }

        if let terminalTabID = target.terminalTabID?.nilIfEmpty {
            _ = KittyCLIRunner.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["focus-tab", "--match", "id:\(terminalTabID)"])
            )
        }
        if let stableTerminalID = target.terminalStableID?.nilIfEmpty,
           KittyCLIRunner.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(stableTerminalID)"])
           ) != nil {
            return true
        }
        if let terminalWindowID = target.terminalWindowID?.nilIfEmpty,
           KittyCLIRunner.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(terminalWindowID)"])
           ) != nil {
            return true
        }

        guard let output = KittyCLIRunner.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["ls"])
              ),
              let data = output.data(using: .utf8),
              let osWindows = try? JSONDecoder().decode([KittyOSWindow].self, from: data)
        else {
            return false
        }

        let ttyVariants = target.tty.map(KittyCLIRunner.ttyVariants) ?? []
        let targetPath = KittyCLIRunner.normalizedPath(target.projectPath)

        for osWindow in osWindows {
            for tab in osWindow.tabs ?? [] {
                for window in tab.windows ?? [] {
                    let ttyMatches = ttyVariants.contains(window.tty ?? "")
                    let cwdMatches = targetPath != nil
                        && targetPath == KittyCLIRunner.normalizedPath(window.cwd ?? window.foregroundProcesses?.first?.cwd)
                    guard ttyMatches || cwdMatches else { continue }

                    if let tabId = tab.id {
                        _ = KittyCLIRunner.run(
                            executable: kitty,
                            arguments: kittyArgs(socketArgs, ["focus-tab", "--match", "id:\(tabId)"])
                        )
                    }
                    if let windowId = window.id,
                       KittyCLIRunner.run(
                            executable: kitty,
                            arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(windowId)"])
                       ) != nil {
                        return true
                    }
                }
            }
        }

        return false
    }

    private func kittyArgs(_ socketArgs: [String], _ commandArgs: [String]) -> [String] {
        ["@"] + socketArgs + commandArgs
    }
}

// MARK: - Readiness

private struct KittyReadinessProvider: TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus {
        KittyCLIRunner.commandPath() != nil ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        let status = KittyConfig.status()
        guard status.kittyInstalled else {
            return [.cliAvailable(name: "kitty")]
        }
        var requirements: [TerminalRequirement] = []
        if status.configuredSocket == nil {
            requirements.append(.configPatched(file: KittyConfig.configURL.path))
        } else if !status.configuredSocketAlive {
            requirements.append(.appRestartRequired(appName: "Kitty"))
        }
        return requirements
    }

    func setupActions() -> [TerminalSetupAction] {
        guard KittyCLIRunner.commandPath() != nil else { return [] }

        var actions: [TerminalSetupAction] = [
            TerminalSetupAction(
                id: "kitty.configure",
                title: "Apply Fix",
                kind: .runAutomaticFix,
                perform: {
                    let result = try KittyConfig.ensureConfigured()
                    let message: String
                    if result.changed {
                        if let backupURL = result.backupURL {
                            message = "Updated kitty.conf. Backup: \(backupURL.lastPathComponent). Restart Kitty or reopen a Kitty window."
                        } else {
                            message = "Created kitty.conf. Restart Kitty or reopen a Kitty window."
                        }
                    } else {
                        message = "Kitty config already contains the required settings. If focus still looks unavailable, reopen a Kitty window so the live socket appears."
                    }
                    return TerminalSetupActionOutcome(message: message)
                }
            )
        ]

        actions.append(
            TerminalSetupAction(
                id: "kitty.openConfig",
                title: "Open Config",
                kind: .openConfigFile,
                perform: {
                    NSWorkspace.shared.open(KittyConfig.configURL.deletingLastPathComponent())
                    return .none
                }
            )
        )

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.kovidgoyal.kitty") {
            actions.append(
                TerminalSetupAction(
                    id: "kitty.openApp",
                    title: "Open Kitty",
                    kind: .openApp,
                    perform: {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                        return .none
                    }
                )
            )
        }

        return actions
    }
}

// MARK: - Setup wizard

private struct KittySetupWizard: TerminalSetupProviding {
    let setupTitle = "Kitty"
    let setupActionTitle = "Configure Kitty"
    var setupConfigURL: URL? { KittyConfig.configURL }

    func installationStatus() -> TerminalInstallationStatus {
        KittyCLIRunner.commandPath() != nil ? .installed : .notInstalled
    }

    func setupRequirements() -> [TerminalRequirement] {
        // Same shape as the readiness provider — these protocols
        // overlap on the setup-status field by design.
        KittyReadinessProvider().setupRequirements()
    }

    func setupActions() -> [TerminalSetupAction] {
        KittyReadinessProvider().setupActions()
    }

    func setupStatus() -> TerminalSetupStatus {
        let status = KittyConfig.status()
        let detail = [status.configuredSocket, status.liveSocket]
            .compactMap { $0 }
            .joined(separator: "\nLive: ")
        return TerminalSetupStatus(
            isReady: status.isReady,
            isAvailable: status.kittyInstalled,
            summary: status.summary,
            detail: detail.isEmpty ? nil : "Configured: \(detail)"
        )
    }

    func ensureSetup() throws -> TerminalSetupResult {
        let result = try KittyConfig.ensureConfigured()
        let message: String
        if result.changed {
            if let backupURL = result.backupURL {
                message = "Updated kitty.conf. Backup: \(backupURL.lastPathComponent). Restart Kitty or reopen a Kitty window."
            } else {
                message = "Created kitty.conf. Restart Kitty or reopen a Kitty window."
            }
        } else {
            message = "Kitty config already contains the required settings. If focus still looks unavailable, reopen a Kitty window so the live socket appears."
        }
        return TerminalSetupResult(changed: result.changed, message: message, backupURL: result.backupURL)
    }
}

// MARK: - Config / socket helpers

private enum KittyConfig {
    struct Status: Equatable {
        let kittyInstalled: Bool
        let configuredSocket: String?
        let configuredSocketAlive: Bool
        let liveSocket: String?

        var isReady: Bool {
            kittyInstalled && configuredSocket != nil && configuredSocketAlive
        }

        var summary: String {
            if isReady {
                return "Precise Kitty focus is ready"
            }
            if !kittyInstalled {
                return "Kitty is not installed"
            }
            if configuredSocket == nil {
                return "Kitty remote-control socket is not configured"
            }
            return "Restart Kitty or reopen a Kitty window to create the live remote-control socket"
        }
    }

    struct InstallResult {
        let changed: Bool
        let backupURL: URL?
    }

    static var configURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kitty/kitty.conf")
    }

    static func status() -> Status {
        let socket = configuredSocket()
        return Status(
            kittyInstalled: KittyCLIRunner.commandPath() != nil,
            configuredSocket: socket,
            configuredSocketAlive: socket.map(socketExists) ?? false,
            liveSocket: socket.flatMap(resolvedSocketAddress)
        )
    }

    static func configuredSocket() -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.components(separatedBy: .newlines).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, parts[0] == "listen_on" else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != "none", !value.isEmpty else { return nil }
            return value
        }
        return nil
    }

    static func ensureConfigured() throws -> InstallResult {
        let fileManager = FileManager.default
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var contents = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let alreadyAllowsRemoteControl = hasSetting("allow_remote_control", in: contents) { value in
            ["yes", "socket", "socket-only"].contains(value)
        }
        let alreadyHasListenSocket = configuredSocket() != nil
        guard !alreadyAllowsRemoteControl || !alreadyHasListenSocket else {
            return InstallResult(changed: false, backupURL: nil)
        }

        let backupURL: URL?
        if fileManager.fileExists(atPath: configURL.path) {
            backupURL = configURL.deletingLastPathComponent()
                .appendingPathComponent("kitty.conf.claude-stats-backup-\(timestamp())")
            try fileManager.copyItem(at: configURL, to: backupURL!)
        } else {
            backupURL = nil
        }

        if !contents.isEmpty, !contents.hasSuffix("\n") {
            contents += "\n"
        }
        contents += "\n#: Claude Statistics terminal focus\n"
        if !alreadyAllowsRemoteControl {
            contents += "allow_remote_control socket-only\n"
        }
        if !alreadyHasListenSocket {
            contents += "listen_on unix:/tmp/kitty-\(NSUserName())\n"
        }

        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return InstallResult(changed: true, backupURL: backupURL)
    }

    static func socketArgs(terminalSocket: String?) -> [String]? {
        if let terminalSocket = terminalSocket?.nilIfEmpty {
            guard let resolved = resolvedSocketAddress(terminalSocket) else { return nil }
            return ["--to", resolved]
        }
        guard let configured = configuredSocket(),
              let resolved = resolvedSocketAddress(configured)
        else { return nil }
        return ["--to", resolved]
    }

    static func socketExists(_ address: String) -> Bool {
        resolvedSocketAddress(address) != nil
    }

    static func resolvedSocketAddress(_ address: String) -> String? {
        guard address.hasPrefix("unix:") else { return address }
        let rawPath = String(address.dropFirst("unix:".count))
        guard !rawPath.hasPrefix("@") else { return address }

        let resolvedPath = localSocketPath(for: rawPath)
        if FileManager.default.fileExists(atPath: resolvedPath) {
            return "unix:\(resolvedPath)"
        }
        guard let matchedPath = matchingLiveSocketPath(for: resolvedPath) else { return nil }
        return "unix:\(matchedPath)"
    }

    private static func hasSetting(
        _ key: String,
        in contents: String,
        accepts: (String) -> Bool
    ) -> Bool {
        for rawLine in contents.components(separatedBy: .newlines).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, parts[0] == key else { continue }
            return accepts(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return false
    }

    private static func localSocketPath(for rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return NSTemporaryDirectory() + expanded
    }

    private static func matchingLiveSocketPath(for configuredPath: String) -> String? {
        let url = URL(fileURLWithPath: configuredPath)
        let directoryURL = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent

        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let matches = candidates
            .filter { candidate in
                let name = candidate.lastPathComponent
                return name == baseName || name.hasPrefix(baseName + "-")
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        return matches.first?.path
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - CLI runner

private enum KittyCLIRunner {
    static func commandPath() -> String? {
        if let found = which("kitty") { return found }
        let candidates = [
            "/Applications/kitty.app/Contents/MacOS/kitty",
            "/opt/homebrew/bin/kitty",
            "/usr/local/bin/kitty"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(executable: String, arguments: [String]) -> String? {
        guard let result = runWithStatus(executable: executable, arguments: arguments) else {
            return nil
        }
        guard result.terminationStatus == 0 else { return nil }
        return result.stdout
    }

    static func runWithStatus(executable: String, arguments: [String]) -> ProcessResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }

    static func ttyVariants(_ tty: String) -> Set<String> {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        return [tty, trimmed, "/dev/\(trimmed)"]
    }

    static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfEmpty else { return nil }
        var resolved = (path as NSString).expandingTildeInPath
        if resolved.hasPrefix("file://"), let url = URL(string: resolved) {
            resolved = url.path
        }
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    private static func which(_ command: String) -> String? {
        runWithStatus(executable: "/usr/bin/which", arguments: [command])?
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    struct ProcessResult {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }
}

// MARK: - kitty @ ls JSON shape

private struct KittyOSWindow: Decodable {
    let id: Int?
    let tabs: [KittyTab]?
}

private struct KittyTab: Decodable {
    let id: Int?
    let windows: [KittyWindow]?
}

private struct KittyWindow: Decodable {
    let id: Int?
    let tty: String?
    let cwd: String?
    let foregroundProcesses: [KittyProcess]?

    enum CodingKeys: String, CodingKey {
        case id, tty, cwd
        case foregroundProcesses = "foreground_processes"
    }
}

private struct KittyProcess: Decodable {
    let cwd: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
