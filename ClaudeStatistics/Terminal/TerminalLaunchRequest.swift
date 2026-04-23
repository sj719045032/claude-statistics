import Foundation

struct TerminalLaunchRequest {
    let executable: String
    let arguments: [String]
    let cwd: String
    let environment: [String: String]

    init(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
    }

    var commandOnly: String {
        TerminalShellCommand.command(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
    }

    var commandInWorkingDirectory: String {
        "cd \(TerminalShellCommand.escape(cwd)) && \(commandOnly)"
    }
}

enum TerminalShellCommand {
    static func escape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let prefix = environment.keys.sorted().map { key in
            "\(key)=\(escape(environment[key] ?? ""))"
        }
        let envCommand = prefix.isEmpty ? [] : ["env"] + prefix
        return (envCommand + [escape(executable)] + arguments.map(escape)).joined(separator: " ")
    }

    static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

