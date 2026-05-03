import Foundation

public enum TerminalLaunchIntent: Sendable, Equatable {
    case command
    case newSession(metadata: [String: String] = [:])
    case resumeSession(sessionID: String, metadata: [String: String] = [:])

    public var metadata: [String: String] {
        switch self {
        case .command:
            return [:]
        case .newSession(let metadata), .resumeSession(_, let metadata):
            return metadata
        }
    }

    public var resumeSessionID: String? {
        guard case .resumeSession(let sessionID, _) = self else { return nil }
        return sessionID
    }
}

/// Describes a single CLI launch a terminal plugin should run on the
/// user's behalf. Carries enough information to either fork a process
/// directly or build a shell-quoted command line for AppleScript /
/// remote-control / `cli` paths.
public struct TerminalLaunchRequest: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let cwd: String
    public let environment: [String: String]
    public let intent: TerminalLaunchIntent

    public init(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String] = [:],
        intent: TerminalLaunchIntent = .command
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.intent = intent
    }

    /// Shell-quoted command line *without* a leading `cd`. Use when the
    /// terminal control already places you in `cwd`.
    public var commandOnly: String {
        TerminalShellCommand.command(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
    }

    /// `cd <cwd> && <commandOnly>` — the form most AppleScript /
    /// remote-control launchers prefer.
    public var commandInWorkingDirectory: String {
        "cd \(TerminalShellCommand.escape(cwd)) && \(commandOnly)"
    }
}

/// Shell-escaping helpers shared between the host and any terminal
/// plugin that builds a command line for AppleScript / CLI control.
public enum TerminalShellCommand {
    /// POSIX single-quote escape: `'value with spaces'` → `'value with spaces'`.
    public static func escape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(
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

    public static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
