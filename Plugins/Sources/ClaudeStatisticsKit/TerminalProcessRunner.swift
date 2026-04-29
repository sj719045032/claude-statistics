import Foundation

/// Synchronous Process runner with stdout/stderr capture and a hard
/// timeout. Used by hook installer wrappers, terminal-focus probes,
/// and similar short-lived shell calls. Lives in the SDK so plugins
/// can run shell commands without re-implementing the timeout +
/// SIGKILL escalation logic.
public struct TerminalProcessRunResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let terminationStatus: Int32

    public init(stdout: String, stderr: String, terminationStatus: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
    }
}

public enum TerminalProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 2.0
    ) -> TerminalProcessRunResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = Foundation.ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            stdoutData = data
            lock.unlock()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            stderrData = data
            lock.unlock()
            group.leave()
        }

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            DiagnosticLogger.shared.warning(
                "Terminal process timed out executable=\(executable) args=\(arguments.joined(separator: " ")) timeout=\(timeout)"
            )
            process.terminate()
            if termination.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 0.5)
            }
            _ = group.wait(timeout: .now() + 0.5)
            return nil
        }

        group.wait()

        return TerminalProcessRunResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }
}
