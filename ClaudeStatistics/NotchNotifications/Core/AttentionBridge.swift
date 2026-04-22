import Foundation

final class AttentionBridge {
    weak var notchCenter: NotchNotificationCenter?

    private let socketPath: String
    private let socketQueue = DispatchQueue(label: "com.claude-stats.attention-socket")
    private var listenSource: DispatchSourceRead?
    private var serverFd: Int32 = -1

    init() {
        socketPath = "/tmp/claude-stats-attention-\(getuid()).sock"
    }

    func start() {
        socketQueue.async { [weak self] in
            self?.startListening()
        }
    }

    func stop() {
        socketQueue.async { [weak self] in
            guard let self else { return }
            self.listenSource?.cancel()
            self.listenSource = nil
            if self.serverFd >= 0 {
                close(self.serverFd)
                self.serverFd = -1
            }
            unlink(self.socketPath)
        }
    }

    // MARK: - Private

    private func startListening() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dest, src.baseAddress, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if bindResult < 0 {
            unlink(socketPath)
            let retryResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if retryResult < 0 {
                close(fd); return
            }
        }
        // Codex hooks can run from helper/sandboxed processes that cannot
        // connect to a user-only socket. Match Codex Island's permissive
        // local-hook bridge so provider hooks can reach the app reliably.
        chmod(socketPath, 0o777)

        guard listen(fd, 16) == 0 else { close(fd); unlink(socketPath); return }

        serverFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let clientFd = accept(self.serverFd, nil, nil)
            if clientFd >= 0 {
                self.handleConnection(clientFd)
            }
        }
        source.resume()
        listenSource = source
    }

    private func handleConnection(_ fd: Int32) {
        socketQueue.async { [weak self] in
            guard let self else { close(fd); return }
            guard let line = readLine(fd: fd) else { close(fd); return }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(WireMessage.self, from: data) else {
                close(fd); return
            }

            let kind: AttentionKind
            switch msg.event {
            case "PermissionRequest", "ToolPermission":
                kind = .permissionRequest(
                    tool: msg.tool_name ?? "",
                    input: msg.tool_input ?? [:],
                    toolUseId: msg.tool_use_id ?? ""
                )
            case "StopFailure":
                kind = .taskFailed(summary: msg.message)
            case "Stop":
                // Claude finished its turn cleanly — surface as "task done".
                // The notification `idle_prompt` below (Claude proactively
                // asks the user something) stays as .waitingInput, since
                // that's a genuine "please respond" prompt.
                kind = .taskDone(summary: msg.message)
            case "SubagentStop":
                kind = .activityPulse
            case "SessionStart":
                kind = .sessionStart(source: msg.message)
            case "SessionEnd":
                kind = .sessionEnd
            case "Notification":
                switch msg.notification_type {
                case "idle_prompt":
                    kind = .waitingInput(message: msg.message)
                case "permission_prompt":
                    kind = .activityPulse
                default:
                    kind = .activityPulse
                }
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "PreCompact", "PostCompact":
                kind = .activityPulse
            default:
                kind = .activityPulse
            }

            let provider: ProviderKind
            switch msg.provider {
            case "codex":  provider = .codex
            case "gemini": provider = .gemini
            default:       provider = .claude
            }

            // Per-provider master switch. When a provider is disabled we close
            // the connection immediately without spinning up a PendingResponse
            // so the hook script sees "no decision" and falls through to the
            // CLI's native behavior. Nothing is enqueued, nothing is tracked.
            guard NotchPreferences.isEnabled(provider) else {
                close(fd)
                return
            }

            let pending: PendingResponse?
            if msg.expects_response == true {
                pending = PendingResponse(fd: fd, timeoutMs: msg.timeout_ms ?? 30000)
            } else {
                close(fd)
                pending = nil
            }

            let event = AttentionEvent(
                id: UUID(),
                provider: provider,
                rawEventName: msg.event,
                notificationType: msg.notification_type,
                toolName: msg.tool_name,
                toolInput: msg.tool_input,
                toolUseId: msg.tool_use_id,
                toolResponse: msg.tool_response,
                message: msg.message,
                sessionId: msg.session_id ?? "",
                projectPath: msg.cwd,
                transcriptPath: msg.transcript_path,
                tty: msg.tty,
                pid: msg.pid.map { Int32($0) },
                terminalName: msg.terminal_name,
                terminalSocket: msg.terminal_socket,
                terminalWindowID: msg.terminal_window_id,
                terminalTabID: msg.terminal_tab_id,
                terminalStableID: msg.terminal_surface_id,
                receivedAt: Date(),
                kind: kind,
                pending: pending
            )

            let msgLen = msg.message?.count ?? 0
            let msgTail = msg.message.map { String($0.suffix(40)) } ?? ""
            DiagnosticLogger.shared.info(
                "Bridge rx event=\(event.rawEventName) provider=\(event.provider.rawValue) session=\(event.sessionId) tool=\(event.toolName ?? "-") toolUseId=\(event.toolUseId ?? "-") expectsResp=\(msg.expects_response == true) notif=\(event.notificationType ?? "-") msgLen=\(msgLen) tail=\(msgTail.debugDescription)"
            )

            DispatchQueue.main.async { [weak self] in
                self?.notchCenter?.enqueue(event)
            }
        }
    }

    private func readLine(fd: Int32) -> String? {
        var result = Data()
        var byte = UInt8(0)
        while true {
            let n = withUnsafeMutableBytes(of: &byte) { ptr in
                read(fd, ptr.baseAddress, 1)
            }
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            result.append(byte)
        }
        guard !result.isEmpty else { return nil }
        return String(data: result, encoding: .utf8)
    }
}

// MARK: - Wire protocol

private struct WireMessage: Decodable {
    let v: Int?
    let provider: String?
    let event: String
    let status: String?
    let notification_type: String?
    let session_id: String?
    let cwd: String?
    let pid: Int?
    let tty: String?
    let terminal_name: String?
    let terminal_socket: String?
    let terminal_window_id: String?
    let terminal_tab_id: String?
    let terminal_surface_id: String?
    let transcript_path: String?
    let tool_name: String?
    let tool_input: [String: JSONValue]?
    let tool_use_id: String?
    let tool_response: String?
    let message: String?
    let expects_response: Bool?
    let timeout_ms: Int?
}
