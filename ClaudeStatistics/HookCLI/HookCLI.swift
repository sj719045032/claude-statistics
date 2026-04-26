import Darwin
import Foundation

enum HookCLI {
    private static let providerFlag = "--claude-stats-hook-provider"

    static func runIfNeeded(arguments: [String]) -> Int32? {
        guard let flagIndex = arguments.firstIndex(of: providerFlag) else {
            return nil
        }

        let providerIndex = arguments.index(after: flagIndex)
        guard providerIndex < arguments.endIndex,
              let provider = ProviderKind(rawValue: arguments[providerIndex]) else {
            return 1
        }

        return HookRunner(provider: provider).run()
    }
}

enum HookDefaults {
    static let shortIOTimeoutSeconds = 2
    static let approvalTimeoutMs = 280_000
    static let approvalResponseTimeoutSeconds = approvalTimeoutMs / 1000
    static let maxToolResponseLength = 1200
}

struct HookAction {
    let message: [String: Any]
    let expectsResponse: Bool
    let responseTimeoutSeconds: Int
    let printDecision: ((String?) -> Void)?

    init(
        message: [String: Any],
        expectsResponse: Bool = false,
        responseTimeoutSeconds: Int = HookDefaults.shortIOTimeoutSeconds,
        printDecision: ((String?) -> Void)? = nil
    ) {
        self.message = message
        self.expectsResponse = expectsResponse
        self.responseTimeoutSeconds = responseTimeoutSeconds
        self.printDecision = printDecision
    }
}

struct HookRunner {
    let provider: ProviderKind

    func run() -> Int32 {
        guard let payload = readPayload() else {
            return 0
        }

        let action: HookAction?
        switch provider {
        case .claude:
            action = buildClaudeAction(payload: payload)
        case .codex:
            action = buildCodexAction(payload: payload)
        case .gemini:
            action = buildGeminiAction(payload: payload)
        }

        guard let action else { return 0 }
        logHookDispatch(for: action.message, expectsResponse: action.expectsResponse)
        let decision = socketDecision(
            for: action.message,
            expectsResponse: action.expectsResponse,
            responseTimeoutSeconds: action.responseTimeoutSeconds
        )
        action.printDecision?(decision)
        return 0
    }

    func baseMessage(
        provider: ProviderKind,
        event: String,
        status: String,
        notificationType: String?,
        payload: [String: Any],
        cwd: String?,
        terminalName: String?,
        terminalContext: TerminalContext
    ) -> [String: Any] {
        var message: [String: Any] = [
            "v": 1,
            "auth_token": AttentionBridgeAuth.loadToken() ?? "",
            "provider": provider.rawValue,
            "event": event,
            "status": status,
            "pid": Int(getppid()),
            "expects_response": false,
        ]

        set(&message, "notification_type", notificationType)
        set(&message, "session_id", stringValue(payload["session_id"]))
        set(&message, "cwd", cwd)
        set(&message, "transcript_path", stringValue(payload["transcript_path"]))
        set(&message, "tty", currentTTY(pid: Int(getppid())))
        set(&message, "terminal_name", terminalName)
        set(&message, "terminal_socket", terminalContext.socket)
        set(&message, "terminal_window_id", terminalContext.windowID)
        set(&message, "terminal_tab_id", terminalContext.tabID)
        set(&message, "terminal_surface_id", terminalContext.surfaceID)

        return message
    }

    private func socketDecision(
        for message: [String: Any],
        expectsResponse: Bool,
        responseTimeoutSeconds: Int
    ) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []) else {
            return nil
        }

        let payloadData = data + Data([0x0A])
        let diagnosticContext = HookSocketDiagnosticContext(
            provider: provider,
            event: stringValue(message["event"]) ?? "-",
            sessionId: stringValue(message["session_id"]) ?? "-",
            toolName: stringValue(message["tool_name"]) ?? "-",
            toolUseId: stringValue(message["tool_use_id"]) ?? "-"
        )
        for path in socketPathCandidates {
            guard let responseData = sendToSocket(
                path: path,
                payload: payloadData,
                expectsResponse: expectsResponse,
                responseTimeoutSeconds: responseTimeoutSeconds,
                diagnosticContext: diagnosticContext
            ) else {
                continue
            }

            guard expectsResponse else { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                DiagnosticLogger.shared.warning(
                    "HookCLI invalid response provider=\(provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) bytes=\(responseData.count)"
                )
                continue
            }
            return stringValue(object["decision"])
        }

        let joinedPaths = socketPathCandidates.joined(separator: ",")
        DiagnosticLogger.shared.warning(
            "HookCLI socket delivery failed provider=\(provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) tool=\(diagnosticContext.toolName) toolUseId=\(diagnosticContext.toolUseId) expectsResp=\(expectsResponse) paths=\(joinedPaths)"
        )
        return nil
    }

    private var socketPathCandidates: [String] {
        [AttentionBridgeAuth.socketPath]
    }

    private func logHookDispatch(for message: [String: Any], expectsResponse: Bool) {
        let event = stringValue(message["event"]) ?? "-"
        let sessionId = stringValue(message["session_id"]) ?? "-"
        let tool = stringValue(message["tool_name"]) ?? "-"
        let toolUseId = stringValue(message["tool_use_id"]) ?? "-"
        let cwd = stringValue(message["cwd"]) ?? "-"
        let tty = stringValue(message["tty"]) ?? "-"
        DiagnosticLogger.shared.verbose(
            "HookCLI dispatch provider=\(provider.rawValue) event=\(event) session=\(sessionId) tool=\(tool) toolUseId=\(toolUseId) expectsResp=\(expectsResponse) cwd=\(cwd) tty=\(tty)"
        )
    }
}

struct HookSocketDiagnosticContext {
    let provider: ProviderKind
    let event: String
    let sessionId: String
    let toolName: String
    let toolUseId: String
}

struct TerminalContext {
    var socket: String?
    var windowID: String?
    var tabID: String?
    var surfaceID: String?
}

func resolvedHookCWD(payload: [String: Any]) -> String? {
    if let cwd = stringValue(payload["cwd"])?.trimmingCharacters(in: .whitespacesAndNewlines),
       !cwd.isEmpty {
        return cwd
    }

    if let pwd = ProcessInfo.processInfo.environment["PWD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !pwd.isEmpty {
        return pwd
    }

    let currentDirectory = FileManager.default.currentDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return currentDirectory.isEmpty ? nil : currentDirectory
}

func set(_ object: inout [String: Any], _ key: String, _ value: Any?) {
    guard let value else { return }
    object[key] = value
}

private func readPayload() -> [String: Any]? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func printJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func printCodexPermissionDecision(_ decision: String?) {
    switch decision {
    case "allow":
        printJSON([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                ],
            ],
        ])
    case "deny":
        printJSON([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "deny",
                    "message": "Denied via Claude Statistics",
                ],
            ],
        ])
    default:
        printJSON([:])
    }
}

func printClaudePermissionDecision(_ decision: String?) {
    switch decision {
    case "allow":
        printJSON([
            "behavior": "allow",
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                ],
            ],
        ])
    case "deny":
        printJSON([
            "behavior": "deny",
            "message": "Denied via Claude Statistics",
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "deny",
                    "message": "Denied via Claude Statistics",
                ],
            ],
        ])
    default:
        printJSON([:])
    }
}

// MARK: - Payload normalizer — moved to HookPayloadNormalizer.swift

// MARK: - Terminal context — moved to TerminalContextDetector.swift

// MARK: - Socket client — moved to HookSocketClient.swift

struct CommandDiagnostic {
    let stdout: String?
    let stderr: String
    let exitCode: Int32?
}

func commandOutputDiagnostic(_ executable: String, args: [String], timeout: TimeInterval = 1.0) -> CommandDiagnostic {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    task.standardOutput = stdoutPipe
    task.standardError = stderrPipe
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in finished.signal() }
    do { try task.run() } catch {
        return CommandDiagnostic(stdout: nil, stderr: "launch_failed:\(error.localizedDescription)", exitCode: nil)
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        _ = finished.wait(timeout: .now() + 0.2)
        return CommandDiagnostic(stdout: nil, stderr: "timeout_\(timeout)s", exitCode: nil)
    }
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdoutText = String(data: stdoutData, encoding: .utf8)
    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
    return CommandDiagnostic(stdout: stdoutText, stderr: stderrText, exitCode: task.terminationStatus)
}

func commandOutput(_ executable: String, args: [String], timeout: TimeInterval = 1.0) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args

    let stdout = Pipe()
    task.standardOutput = stdout
    task.standardError = Pipe()
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in
        finished.signal()
    }

    do {
        try task.run()
    } catch {
        return nil
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        _ = finished.wait(timeout: .now() + 0.2)
        return nil
    }

    guard task.terminationStatus == 0 else { return nil }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func hookGhosttyLog(_ message: String) {
    DiagnosticLogger.shared.info("Hook ghostty \(message)")
}

/// Background poller that aborts a HookCLI socket read once the host
/// app stops listening. The host's `AttentionBridge.start()` writes its
/// pid to `AttentionBridgeAuth.pidPath` and clears it on stop; if either
/// the file disappears or `kill(pid, 0)` reports ESRCH, we
/// `shutdown(SHUT_RDWR)` the socket so the blocking `read()` returns
/// EOF instead of waiting out the full 280s permission timeout.
final class HookHostWatchdog {
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private var interrupted = false
    private let pollInterval: TimeInterval

    init(fd: Int32, pollInterval: TimeInterval = 5.0) {
        self.fd = fd
        self.pollInterval = pollInterval
    }

    var didInterrupt: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                self.lock.lock()
                let shouldStop = self.stopped
                self.lock.unlock()
                if shouldStop { return }

                Thread.sleep(forTimeInterval: self.pollInterval)

                self.lock.lock()
                let stillRunning = !self.stopped
                self.lock.unlock()
                if !stillRunning { return }

                if AttentionBridgeAuth.livePid() == nil {
                    self.lock.lock()
                    self.interrupted = true
                    self.stopped = true
                    self.lock.unlock()
                    // Wake the blocking read with EOF. SHUT_RDWR is safer
                    // than close(fd) here because the main thread still
                    // holds fd via `defer { close(fd) }`.
                    shutdown(self.fd, SHUT_RDWR)
                    return
                }
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }
}
