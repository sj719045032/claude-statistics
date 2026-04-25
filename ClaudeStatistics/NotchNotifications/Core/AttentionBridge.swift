import Foundation

enum AttentionBridgeAuth {
    /// Debug vs release isolation lives at the `AppRuntimePaths.rootDirectory`
    /// layer (`.claude-statistics` vs `.claude-statistics-debug`), so the
    /// filenames here can stay simple — no `-debug` suffix needed.
    static var socketPath: String {
        let directory = AppRuntimePaths.ensureRunDirectory() ?? AppRuntimePaths.runDirectory
        return (directory as NSString).appendingPathComponent("attention.sock")
    }

    static var tokenPath: String {
        (AppRuntimePaths.rootDirectory as NSString).appendingPathComponent("attention-token")
    }

    static func ensureToken() -> String? {
        let fm = FileManager.default
        let path = tokenPath

        if let token = loadToken() {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return token
        }

        do {
            guard AppRuntimePaths.ensureRootDirectory() != nil else { return nil }
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try "\(token)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return token
        } catch {
            DiagnosticLogger.shared.warning("AttentionBridge token create failed path=\(path) error=\(error.localizedDescription)")
            return nil
        }
    }

    static func loadToken() -> String? {
        guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}

final class AttentionBridge {
    weak var notchCenter: NotchNotificationCenter?

    private let socketPath: String
    private let authToken: String?
    private let socketQueue = DispatchQueue(label: "com.claude-stats.attention-socket")
    private var listenSource: DispatchSourceRead?
    private var serverFd: Int32 = -1

    init() {
        socketPath = AttentionBridgeAuth.socketPath
        authToken = AttentionBridgeAuth.ensureToken()
    }

    func start() {
        socketQueue.async { [weak self] in
            self?.startListening()
        }
        // Drain pending hook payloads on a background queue so a slow disk
        // doesn't delay the listener coming up. Replay routes through the
        // same `processWireMessage` path the live socket uses.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.drainPendingMessages()
        }
    }

    func stop() {
        socketQueue.async { [weak self] in
            guard let self else { return }
            if let source = self.listenSource {
                self.listenSource = nil
                source.cancel()
            } else if self.serverFd >= 0 {
                close(self.serverFd)
                self.serverFd = -1
            }
            unlink(self.socketPath)
        }
    }

    // MARK: - Private

    private func startListening() {
        guard authToken != nil else { return }

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
        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else { close(fd); unlink(socketPath); return }

        serverFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.serverFd == fd {
                self?.serverFd = -1
            }
        }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let listeningFd = self.serverFd >= 0 ? self.serverFd : fd
            let clientFd = accept(listeningFd, nil, nil)
            if clientFd >= 0 {
                self.handleConnection(clientFd)
            }
        }
        source.resume()
        listenSource = source
    }

    private func handleConnection(_ fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { close(fd); return }
            var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

            guard let line = readLine(fd: fd) else { close(fd); return }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(WireMessage.self, from: data) else {
                close(fd); return
            }

            guard msg.auth_token == self.authToken else {
                DiagnosticLogger.shared.warning("Bridge rejected unauthenticated hook message")
                close(fd)
                return
            }

            self.processWireMessage(msg, fd: fd, replayed: false)
        }
    }

    /// Decode + dispatch logic shared by the live socket path and the disk
    /// replay path. When `fd == nil` (replay) we never spin up a
    /// `PendingResponse` — the original tool has already moved on, so the
    /// hook can't take an answer from us anymore. We still enqueue the event
    /// so `ActiveSessionsTracker` can track its activeTools / completion
    /// state correctly (which is the whole reason we buffered it).
    private func processWireMessage(_ msg: WireMessage, fd: Int32?, replayed: Bool) {
        // kind 的 summary/message associated type 是给 UI 卡片用的。对有
        // transcript 的事件 (Stop/Notification/SessionStart) 优先用 Claude
        // 真实最后一段 text，退化到 WireMessage.message（C 语义的状态串）。
        let kindSummary = msg.commentary_text ?? msg.message
        let kind: AttentionKind
        switch msg.event {
        case "PermissionRequest":
            kind = .permissionRequest(
                tool: msg.tool_name ?? "",
                input: msg.tool_input ?? [:],
                toolUseId: msg.tool_use_id ?? "",
                interaction: .actionable
            )
        case "ToolPermission":
            kind = .permissionRequest(
                tool: msg.tool_name ?? "",
                input: msg.tool_input ?? [:],
                toolUseId: msg.tool_use_id ?? "",
                interaction: .passive
            )
        case "StopFailure":
            kind = .taskFailed(summary: kindSummary)
        case "Stop":
            // Claude finished its turn cleanly — surface as "task done".
            // The notification `idle_prompt` below (Claude proactively
            // asks the user something) stays as .waitingInput, since
            // that's a genuine "please respond" prompt.
            kind = .taskDone(summary: kindSummary)
        case "SubagentStop":
            kind = .activityPulse
        case "SessionStart":
            kind = .sessionStart(source: kindSummary)
        case "SessionEnd":
            kind = .sessionEnd
        case "Notification":
            switch msg.notification_type {
            case "idle_prompt":
                kind = .waitingInput(message: kindSummary)
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
            if let fd { close(fd) }
            return
        }

        let pending: PendingResponse?
        if let fd, msg.expects_response == true {
            pending = PendingResponse(fd: fd, timeoutMs: msg.timeout_ms ?? 30000)
        } else {
            if let fd { close(fd) }
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
            promptText: msg.prompt_text,
            commentaryText: msg.commentary_text,
            commentaryAt: msg.commentary_timestamp.flatMap(AttentionBridge.parseIsoTimestamp),
            kind: kind,
            pending: pending
        )

        let promptLen = msg.prompt_text?.count ?? 0
        let commentaryLen = msg.commentary_text?.count ?? 0
        let msgLen = msg.message?.count ?? 0
        DiagnosticLogger.shared.verbose(
            "Bridge rx event=\(event.rawEventName) provider=\(event.provider.rawValue) session=\(event.sessionId) tool=\(event.toolName ?? "-") toolUseId=\(event.toolUseId ?? "-") expectsResp=\(msg.expects_response == true) replayed=\(replayed) notif=\(event.notificationType ?? "-") promptLen=\(promptLen) commentaryLen=\(commentaryLen) msgLen=\(msgLen) commentaryTs=\(msg.commentary_timestamp ?? "-") parsedTs=\(event.commentaryAt?.timeIntervalSince1970.description ?? "-")"
        )

        // On permission-like events, dump the tool_input schema (keys +
        // JSON-type of each value, NOT the full content) so we can see
        // the per-provider shape without leaking secrets from user
        // commands or file paths. Lets us fill the permissionPreview
        // field-mapping table with ground truth instead of guesswork.
        if event.rawEventName == "PermissionRequest" || event.rawEventName == "ToolPermission" {
            let schema: String = {
                guard let input = msg.tool_input, !input.isEmpty else { return "-" }
                return input
                    .sorted(by: { $0.key < $1.key })
                    .map { "\($0.key):\(Self.jsonKindLabel($0.value))" }
                    .joined(separator: ",")
            }()
            DiagnosticLogger.shared.verbose(
                "Bridge perm-schema provider=\(event.provider.rawValue) tool=\(event.toolName ?? "-") rawEvent=\(event.rawEventName) notif=\(event.notificationType ?? "-") schema={\(schema)}"
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.notchCenter?.enqueue(event)
        }
    }

    /// Read every payload that HookCLI dropped into the pending dir while
    /// we weren't listening (typically during an app restart) and replay it
    /// through the normal pipeline. Files are processed in chronological
    /// order (filename starts with unix-millis), then deleted. Anything
    /// older than `pendingMaxAgeSeconds` is dropped without replay so a
    /// long-offline app doesn't backfill stale "PreToolUse from yesterday"
    /// events that no longer reflect what the user is doing.
    private func drainPendingMessages() {
        let fm = FileManager.default
        let dir = AppRuntimePaths.pendingDirectory
        guard fm.fileExists(atPath: dir) else { return }

        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: dir)
        } catch {
            DiagnosticLogger.shared.warning("Bridge pending dir read failed error=\(error.localizedDescription)")
            return
        }

        let jsonFiles = entries
            .filter { $0.hasSuffix(".json") }
            .sorted()  // unix-millis prefix → lexical = chronological
        guard !jsonFiles.isEmpty else { return }

        let cutoff = Date().addingTimeInterval(-Self.pendingMaxAgeSeconds)
        var replayed = 0
        var dropped = 0
        var failed = 0

        for filename in jsonFiles {
            let path = (dir as NSString).appendingPathComponent(filename)
            defer { try? fm.removeItem(atPath: path) }

            // Filename format: "<unix-millis>-<pid>-<rand>.json".
            // Use the millis prefix as the source of truth for age — file
            // mtime can drift after `mv`-style atomic write or rsync.
            let timestamp: Date? = {
                let head = filename.split(separator: "-").first.map(String.init) ?? ""
                guard let ms = Int64(head) else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            }()
            if let ts = timestamp, ts < cutoff {
                dropped += 1
                continue
            }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let msg = try? JSONDecoder().decode(WireMessage.self, from: data) else {
                failed += 1
                continue
            }
            // Auth check skipped intentionally — these are files we wrote
            // ourselves into a 0o700 user-owned directory. Anyone with
            // write access has the same access level required to install
            // the hooks in the first place, so re-validating the token
            // adds no additional protection.
            processWireMessage(msg, fd: nil, replayed: true)
            replayed += 1
        }

        if replayed > 0 || dropped > 0 || failed > 0 {
            DiagnosticLogger.shared.info(
                "Bridge drained pending payloads replayed=\(replayed) dropped(stale)=\(dropped) failed=\(failed)"
            )
        }
    }

    /// Discard pending payloads older than this. Keeps the long-offline
    /// case from backfilling state that no longer reflects reality.
    private static let pendingMaxAgeSeconds: TimeInterval = 5 * 60

    private func readLine(fd: Int32) -> String? {
        var result = Data()
        var byte = UInt8(0)
        let maxBytes = 1_048_576
        while true {
            let n = withUnsafeMutableBytes(of: &byte) { ptr in
                read(fd, ptr.baseAddress, 1)
            }
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            result.append(byte)
            if result.count > maxBytes {
                DiagnosticLogger.shared.warning("Bridge rejected oversized hook message bytes=\(result.count)")
                return nil
            }
        }
        guard !result.isEmpty else { return nil }
        return String(data: result, encoding: .utf8)
    }

    /// Shared parser for the hook's ISO-8601 `message_timestamp` field. The
    /// Claude transcript timestamps use fractional seconds + 'Z' (e.g.
    /// "2026-04-24T10:42:56.566Z"), which ISO8601DateFormatter can handle
    /// when told to include fractional seconds.
    static func parseIsoTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let d = fractionalIsoFormatter.date(from: trimmed) { return d }
        return isoFormatter.date(from: trimmed)
    }

    private static let fractionalIsoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Short label for a JSONValue's kind, used by permission-schema logs.
    /// Arrays/objects include the element count so we can spot `edits: array(3)`.
    static func jsonKindLabel(_ value: JSONValue) -> String {
        switch value {
        case .string:             return "string"
        case .number:             return "number"
        case .bool:               return "bool"
        case .null:               return "null"
        case .array(let items):   return "array(\(items.count))"
        case .object(let dict):   return "object(\(dict.count))"
        }
    }
}

// MARK: - Wire protocol

private struct WireMessage: Decodable {
    let v: Int?
    let auth_token: String?
    let provider: String?
    let event: String
    let status: String?
    let notification_type: String?
    let session_id: String?
    let cwd: String?
    let transcript_path: String?
    let pid: Int?
    let tty: String?
    let terminal_name: String?
    let terminal_socket: String?
    let terminal_window_id: String?
    let terminal_tab_id: String?
    let terminal_surface_id: String?
    let tool_name: String?
    let tool_input: [String: JSONValue]?
    let tool_use_id: String?
    let tool_response: String?
    /// Status string / tool command description (semantic C and D). Read by
    /// AttentionEvent.livePreview (.waitingInput / .taskDone / .taskFailed)
    /// and by PermissionRequestCard. NOT read as prompt or commentary.
    let message: String?
    /// The user's typed prompt. Only UserPromptSubmit writes this. Consumed
    /// by AttentionEvent.livePrompt. (Semantic A)
    let prompt_text: String?
    /// Claude's assistant text — the actual agent commentary. Any event whose
    /// normalizer can read it from the transcript writes it here. Consumed
    /// by AttentionEvent.liveProgressNote. (Semantic B)
    let commentary_text: String?
    /// ISO-8601 of the transcript entry that produced `commentary_text`, so
    /// downstream can place `latestProgressNoteAt` at when the text was
    /// actually written, not when the hook fired.
    let commentary_timestamp: String?
    let expects_response: Bool?
    let timeout_ms: Int?
}
