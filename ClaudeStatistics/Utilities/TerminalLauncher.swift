import AppKit
import Foundation

enum TerminalApp: String, CaseIterable, Identifiable {
    case auto = "Auto"
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
        case .iterm: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
        case .terminal: return true // always available
        case .warp: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") != nil
        case .kitty: return FileManager.default.fileExists(atPath: "/Applications/kitty.app")
        case .alacritty: return FileManager.default.fileExists(atPath: "/Applications/Alacritty.app")
        }
    }
}

enum TerminalLauncher {
    /// Open a new Claude session in the same directory
    static func openNewSession(_ session: Session) {
        let cwd = session.cwd ?? decodeProjectPath(session.projectPath) ?? NSHomeDirectory()
        let command = "cd \(shellEscape(cwd)) && claude"
        launchInTerminal(command: command)
    }

    /// Open a Claude session in the user's terminal
    static func openSession(_ session: Session) {
        let cwd = session.cwd ?? decodeProjectPath(session.projectPath) ?? NSHomeDirectory()
        let command = "cd \(shellEscape(cwd)) && claude --resume \(shellEscape(session.id))"
        launchInTerminal(command: command)
    }

    private static func launchInTerminal(command: String) {
        let preferred = TerminalApp.preferred
        // Extract cwd from command for terminal apps that need it separately
        let cwd = NSHomeDirectory()
        switch preferred {
        case .auto:
            if TerminalApp.iterm.isInstalled {
                openInITerm(command: command)
            } else if TerminalApp.warp.isInstalled {
                openInWarp(command: command)
            } else {
                openInTerminalApp(command: command)
            }
        case .iterm:
            openInITerm(command: command)
        case .terminal:
            openInTerminalApp(command: command)
        case .warp:
            openInWarp(command: command)
        case .kitty:
            openInKitty(command: command, cwd: cwd)
        case .alacritty:
            openInAlacritty(command: command, cwd: cwd)
        }
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

    private static func openInWarp(command: String) {
        let script = """
        tell application "Warp"
            activate
        end tell
        delay 0.5
        tell application "System Events"
            tell process "Warp"
                keystroke "t" using command down
                delay 0.3
                keystroke "\(escapeAppleScript(command))"
                key code 36
            end tell
        end tell
        """
        runOsascript(script)
    }

    // MARK: - Kitty

    private static func openInKitty(command: String, cwd: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/kitty.app/Contents/MacOS/kitty")
        process.arguments = ["--single-instance", "--directory", cwd, "bash", "-c", command.replacingOccurrences(of: "cd \(shellEscape(cwd)) && ", with: "") + "; exec bash"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    // MARK: - Alacritty

    private static func openInAlacritty(command: String, cwd: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Alacritty.app/Contents/MacOS/alacritty")
        process.arguments = ["--working-directory", cwd, "-e", "bash", "-c", command.replacingOccurrences(of: "cd \(shellEscape(cwd)) && ", with: "") + "; exec bash"]
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

    /// Decode the encoded project path back to a real filesystem path.
    static func decodeProjectPath(_ encoded: String) -> String? {
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = stripped.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        let fm = FileManager.default
        var currentPath = "/" + parts[0]
        var i = 1

        while i < parts.count {
            let asSubdir = currentPath + "/" + parts[i]
            let asHyphen = currentPath + "-" + parts[i]

            if i == parts.count - 1 {
                if fm.fileExists(atPath: asSubdir) {
                    currentPath = asSubdir
                } else if fm.fileExists(atPath: asHyphen) {
                    currentPath = asHyphen
                } else {
                    currentPath = asSubdir
                }
            } else {
                var isDirSub: ObjCBool = false
                var isDirHyp: ObjCBool = false
                let subExists = fm.fileExists(atPath: asSubdir, isDirectory: &isDirSub) && isDirSub.boolValue
                let hypExists = fm.fileExists(atPath: asHyphen, isDirectory: &isDirHyp) && isDirHyp.boolValue

                if hypExists && !subExists {
                    currentPath = asHyphen
                } else {
                    currentPath = asSubdir
                }
            }
            i += 1
        }

        if fm.fileExists(atPath: currentPath) {
            return currentPath
        }
        return nil
    }

    private static func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
