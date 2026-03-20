import AppKit
import Foundation

enum TerminalLauncher {
    /// Open a Claude session in the user's terminal
    static func openSession(_ session: Session) {
        let cwd = decodeProjectPath(session.projectPath) ?? NSHomeDirectory()
        let command = "cd \(shellEscape(cwd)) && claude --resume \(shellEscape(session.id))"

        // Try iTerm first, then fall back to Terminal.app
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            openInITerm(command: command)
        } else {
            openInTerminalApp(command: command)
        }
    }

    // MARK: - iTerm2

    private static func openInITerm(command: String) {
        // Use "write text" to send the command to a new window's shell session
        // This way the shell stays alive and the command runs inside it
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
    /// Claude encodes `/` as `-`, so `-Users-tinystone-claude-statistics` means `/Users/tinystone/claude-statistics`.
    /// Since directory names can also contain `-`, we greedily try replacing `-` with `/` from left to right,
    /// checking filesystem existence at each step to find the real path.
    static func decodeProjectPath(_ encoded: String) -> String? {
        // Remove leading `-` to get `Users-tinystone-...`
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded

        let parts = stripped.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        let fm = FileManager.default
        // Greedily build path: try to match each segment as a directory
        var currentPath = "/" + parts[0]
        var i = 1

        while i < parts.count {
            // Try extending current last component with `-` (i.e., the `-` was literal)
            // vs starting a new path component (i.e., the `-` was `/`)
            let asSubdir = currentPath + "/" + parts[i]
            let asHyphen = currentPath + "-" + parts[i]

            if i == parts.count - 1 {
                // Last part: prefer whichever exists
                if fm.fileExists(atPath: asSubdir) {
                    currentPath = asSubdir
                } else if fm.fileExists(atPath: asHyphen) {
                    currentPath = asHyphen
                } else {
                    // Default to subdir
                    currentPath = asSubdir
                }
            } else {
                // Not last: prefer the path that exists as a directory so we can keep going
                var isDirSub: ObjCBool = false
                var isDirHyp: ObjCBool = false
                let subExists = fm.fileExists(atPath: asSubdir, isDirectory: &isDirSub) && isDirSub.boolValue
                let hypExists = fm.fileExists(atPath: asHyphen, isDirectory: &isDirHyp) && isDirHyp.boolValue

                if subExists && hypExists {
                    // Both exist — try to look ahead and see which leads to a valid full path
                    // Default to subdir (more common: `-` was `/`)
                    currentPath = asSubdir
                } else if hypExists {
                    currentPath = asHyphen
                } else {
                    // Default to subdir
                    currentPath = asSubdir
                }
            }
            i += 1
        }

        // Verify the final path exists
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
