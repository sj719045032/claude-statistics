import Foundation

enum TerminalCLICommand {
    static func commandPath(_ command: String) -> String? {
        if let found = which(command) {
            return found
        }

        let candidates: [String]
        switch command {
        case "kitty":
            candidates = [
                "/Applications/kitty.app/Contents/MacOS/kitty",
                "/opt/homebrew/bin/kitty",
                "/usr/local/bin/kitty"
            ]
        case "wezterm":
            candidates = [
                "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                "/opt/homebrew/bin/wezterm",
                "/usr/local/bin/wezterm"
            ]
        default:
            candidates = []
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(executable: String, arguments: [String]) -> String? {
        run(executable: executable, arguments: arguments, label: nil)
    }

    static func run(executable: String, arguments: [String], label: String?) -> String? {
        guard let result = TerminalProcessRunner.run(executable: executable, arguments: arguments) else {
            if let label {
                DiagnosticLogger.shared.warning(
                    "\(label) failed args=\(arguments.joined(separator: " ")) stderr=process did not launch"
                )
            }
            return nil
        }
        guard result.terminationStatus == 0 else {
            if let label {
                DiagnosticLogger.shared.warning(
                    "\(label) failed args=\(arguments.joined(separator: " ")) stderr=\(resultErrorSummary(result))"
                )
            }
            return nil
        }
        return result.stdout
    }

    static func ttyVariants(_ tty: String) -> Set<String> {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        return [tty, trimmed, "/dev/\(trimmed)"]
    }

    static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfEmpty else { return nil }
        var resolved = (path as NSString).expandingTildeInPath
        if resolved.hasPrefix("file://"),
           let url = URL(string: resolved) {
            resolved = url.path
        }
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    private static func which(_ command: String) -> String? {
        run(executable: "/usr/bin/which", arguments: [command])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func resultErrorSummary(_ result: TerminalProcessRunResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderr.nilIfEmpty ?? stdout.nilIfEmpty ?? "exit \(result.terminationStatus)"
        return String(message.prefix(300))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
