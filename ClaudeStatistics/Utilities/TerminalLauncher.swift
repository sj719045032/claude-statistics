import AppKit
import Foundation

enum TerminalApp: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case ghostty = "Ghostty"
    case iterm = "iTerm2"
    case terminal = "Terminal"
    case warp = "Warp"
    case kitty = "Kitty"
    case alacritty = "Alacritty"

    var id: String { rawValue }

    static var preferred: TerminalApp {
        let raw = UserDefaults.standard.string(forKey: "preferredTerminal") ?? "Auto"
        return TerminalApp(rawValue: raw) ?? .auto
    }

    static func setPreferred(_ app: TerminalApp) {
        UserDefaults.standard.set(app.rawValue, forKey: "preferredTerminal")
    }

    /// Check if this terminal is installed
    var isInstalled: Bool {
        switch self {
        case .auto: return true
        case .ghostty: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
        case .iterm: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
        case .terminal: return true // always available
        case .warp: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") != nil
        case .kitty: return FileManager.default.fileExists(atPath: "/Applications/kitty.app")
        case .alacritty: return FileManager.default.fileExists(atPath: "/Applications/Alacritty.app")
        }
    }
}

enum TerminalLauncher {
    static func launch(executable: String, arguments: [String], cwd: String) {
        launchInTerminal(cwd: cwd, executable: executable, arguments: arguments)
    }

    private static func launchInTerminal(cwd: String, executable: String, arguments: [String]) {
        let commandOnly = shellCommand(executable: executable, arguments: arguments)
        let command = "cd \(shellEscape(cwd)) && \(commandOnly)"
        let preferred = TerminalApp.preferred
        switch preferred {
        case .auto:
            if TerminalApp.ghostty.isInstalled {
                openInGhostty(cwd: cwd, executable: executable, arguments: arguments)
            } else if TerminalApp.iterm.isInstalled {
                openInITerm(command: command)
            } else if TerminalApp.warp.isInstalled {
                openInWarp(cwd: cwd, executable: executable, arguments: arguments)
            } else {
                openInTerminalApp(command: command)
            }
        case .ghostty:
            openInGhostty(cwd: cwd, executable: executable, arguments: arguments)
        case .iterm:
            openInITerm(command: command)
        case .terminal:
            openInTerminalApp(command: command)
        case .warp:
            openInWarp(cwd: cwd, executable: executable, arguments: arguments)
        case .kitty:
            openInKitty(command: commandOnly, cwd: cwd)
        case .alacritty:
            openInAlacritty(command: commandOnly, cwd: cwd)
        }
    }

    // MARK: - Ghostty

    private static func openInGhostty(cwd: String, executable: String, arguments: [String]) {
        let launchCommand = shellCommand(executable: executable, arguments: arguments)
        let scriptPath = (cwd as NSString).appendingPathComponent(".cs-launch")
        let content = "#!/bin/zsh -l\nrm -f \(shellEscape(scriptPath))\nexec \(launchCommand)\n"
        guard (try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)) != nil
        else { return }

        let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            ?? URL(fileURLWithPath: "/Applications/Ghostty.app")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: scriptPath)],
            withApplicationAt: ghosttyURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - iTerm2

    private static func openInITerm(command: String) {
        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(escapeAppleScript(command))"
            end tell
        end tell
        """
        runOsascript(script)
    }

    // MARK: - Terminal.app

    private static func openInTerminalApp(command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeAppleScript(command))"
        end tell
        """
        runOsascript(script)
    }

    // MARK: - Warp

    private static func openInWarp(cwd: String, executable: String, arguments: [String]) {
        let launchCommand = shellCommand(executable: executable, arguments: arguments)
        let scriptPath = (cwd as NSString).appendingPathComponent(".cs-launch")
        let content = "#!/bin/bash\nrm -f \(shellEscape(scriptPath))\nexec \(launchCommand)\n"
        guard (try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)) != nil
        else { return }

        let warpURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable")
            ?? URL(fileURLWithPath: "/Applications/Warp.app")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: scriptPath)],
            withApplicationAt: warpURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Kitty

    private static func openInKitty(command: String, cwd: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/kitty.app/Contents/MacOS/kitty")
        process.arguments = ["--single-instance", "--directory", cwd, "bash", "-c", command + "; exec bash"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    // MARK: - Alacritty

    private static func openInAlacritty(command: String, cwd: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Alacritty.app/Contents/MacOS/alacritty")
        process.arguments = ["--working-directory", cwd, "-e", "bash", "-c", command + "; exec bash"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    // MARK: - Helpers

    /// Use /usr/bin/osascript process instead of NSAppleScript to avoid sandbox restrictions
    private static func runOsascript(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            // Fallback: try NSAppleScript
            if let script = NSAppleScript(source: source) {
                var err: NSDictionary?
                script.executeAndReturnError(&err)
            }
        }
    }

    private static func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellCommand(executable: String, arguments: [String]) -> String {
        ([shellEscape(executable)] + arguments.map(shellEscape)).joined(separator: " ")
    }

    private static func escapeAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
