import Foundation
import ClaudeStatisticsKit

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
        // Filesystem cleanup runs SYNCHRONOUSLY on the caller's thread.
        // `applicationWillTerminate` calls us and then returns — if we hand
        // unlink/clearPid off to socketQueue the process can exit before the
        // queue drains, leaving an orphan `attention.sock` + stale pid file.
        // Hook clients on the next build window then see ECONNREFUSED instead
        // of ENOENT, which misroutes them in the connect-failure handler and
        // delays the rebind retry path until the file is finally removed.
        unlink(socketPath)
        AttentionBridgeAuth.clearPid()

        // The listen source must be cancelled on its own queue (DispatchSource
        // contract). The cancel handler closes the fd. After unlink above,
        // any in-flight accept just sees the source go down — no new connects
        // can land because the path is already gone.
        socketQueue.async { [weak self] in
            guard let self else { return }
            if let source = self.listenSource {
                self.listenSource = nil
                source.cancel()
            } else if self.serverFd >= 0 {
                close(self.serverFd)
                self.serverFd = -1
            }
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

        // Heartbeat for HookCLI watchdog: hook subprocesses read this to
        // detect host death and abort their long-blocking permission-
        // response reads instead of leaving CLIs hung.
        AttentionBridgeAuth.writePid()
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
        // 真实最后一段 text,退化到 WireMessage.message(C 语义的状态串)。
        let kindSummary = msg.commentary_text ?? msg.message
        let kindBase = WireEventTranslator.translateKind(
            event: msg.event,
            notificationType: msg.notification_type,
            summary: kindSummary
        )
        let kind = WireEventTranslator.resolvePermissionFields(kindBase, in: msg)
        let provider = WireEventTranslator.translateProvider(msg.provider)

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

        let event = WireEventTranslator.makeEvent(
            from: msg,
            provider: provider,
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
                    .map { "\($0.key):\(WireEventTranslator.jsonKindLabel($0.value))" }
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

}
