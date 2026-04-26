import Foundation

// MARK: - Hook Socket Client
func sendToSocket(
    path: String,
    payload: Data,
    expectsResponse: Bool,
    responseTimeoutSeconds: Int,
    diagnosticContext: HookSocketDiagnosticContext
) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        let code = errno
        DiagnosticLogger.shared.warning(
            "HookCLI socket create failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) errno=\(code) reason=\(String(cString: strerror(code)))"
        )
        return nil
    }
    defer { close(fd) }

    var sendTimeout = timeval(tv_sec: HookDefaults.shortIOTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    if expectsResponse {
        var receiveTimeout = timeval(tv_sec: responseTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= maxLength else { return nil }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { destination in
            destination.initialize(repeating: 0, count: maxLength)
            _ = pathBytes.withUnsafeBufferPointer { source in
                memcpy(destination, source.baseAddress, pathBytes.count)
            }
        }
    }

    let connectResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        let code = errno
        DiagnosticLogger.shared.warning(
            "HookCLI socket connect failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path) errno=\(code) reason=\(String(cString: strerror(code)))"
        )
        // App not listening (ECONNREFUSED) or socket file gone (ENOENT) —
        // typically a brief restart window. Persist the payload to the
        // pending dir so AttentionBridge can replay it once the listener is
        // back. Permission requests need a synchronous decision and can't be
        // replayed (the tool will already have run by then), so we only
        // buffer fire-and-forget events.
        if !expectsResponse, code == ECONNREFUSED || code == ENOENT {
            bufferPendingHookPayload(payload: payload, context: diagnosticContext)
        }
        return nil
    }

    guard writeAll(fd: fd, data: payload) else {
        let code = errno
        DiagnosticLogger.shared.warning(
            "HookCLI socket write failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path) errno=\(code) reason=\(String(cString: strerror(code)))"
        )
        // We connected but the write got interrupted (server crashed
        // mid-handshake, EPIPE, etc.). Same recovery path as connect-fail.
        if !expectsResponse {
            bufferPendingHookPayload(payload: payload, context: diagnosticContext)
        }
        return nil
    }

    guard expectsResponse else { return Data() }

    // Host-liveness watchdog: while we block on the long permission-
    // response read (up to 280s), poll `AttentionBridgeAuth.livePid()`
    // every few seconds. If the host died, `shutdown(fd, SHUT_RDWR)`
    // forces our read to return EOF immediately so the CLI doesn't hang.
    let watchdog = HookHostWatchdog(fd: fd)
    watchdog.start()
    defer { watchdog.stop() }

    var response = Data()
    var byte: UInt8 = 0
    while true {
        let bytesRead = withUnsafeMutableBytes(of: &byte) { pointer in
            Darwin.read(fd, pointer.baseAddress, 1)
        }
        if bytesRead < 0 {
            let code = errno
            DiagnosticLogger.shared.warning(
                "HookCLI socket read failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path) errno=\(code) reason=\(String(cString: strerror(code)))"
            )
            return nil
        }
        if bytesRead == 0 {
            if watchdog.didInterrupt {
                DiagnosticLogger.shared.warning(
                    "HookCLI host died mid-wait provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path)"
                )
                return nil
            }
            break
        }
        if byte == 0x0A { break }
        response.append(byte)
    }

    if response.isEmpty {
        DiagnosticLogger.shared.warning(
            "HookCLI socket empty response provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path)"
        )
        return nil
    }

    return response
}

/// Persist a hook payload that couldn't be delivered to the running app's
/// socket. `AttentionBridge.drainPendingMessages()` reads these on next
/// startup and re-injects them through the normal event pipeline.
///
/// File naming: `<unix-millis>-<pid>-<short-uuid>.json`. The leading
/// millis-since-epoch lets the drain side replay in chronological order
/// even if multiple HookCLI instances raced. Atomic write via .tmp + rename
/// so the drain side never sees a half-written file.
private func bufferPendingHookPayload(payload: Data, context: HookSocketDiagnosticContext) {
    let fm = FileManager.default
    guard let pendingDir = AppRuntimePaths.ensurePendingDirectory() else {
        DiagnosticLogger.shared.warning(
            "HookCLI buffer dir create failed event=\(context.event) toolUseId=\(context.toolUseId) path=\(AppRuntimePaths.pendingDirectory)"
        )
        return
    }
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    let pid = ProcessInfo.processInfo.processIdentifier
    let rand = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    let filename = "\(timestampMs)-\(pid)-\(rand).json"
    let finalPath = (pendingDir as NSString).appendingPathComponent(filename)
    let tmpPath = finalPath + ".tmp"
    do {
        try payload.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        try fm.moveItem(atPath: tmpPath, toPath: finalPath)
        DiagnosticLogger.shared.warning(
            "HookCLI buffered to disk provider=\(context.provider.rawValue) event=\(context.event) session=\(context.sessionId) toolUseId=\(context.toolUseId) file=\(filename)"
        )
    } catch {
        try? fm.removeItem(atPath: tmpPath)
        DiagnosticLogger.shared.warning(
            "HookCLI buffer write failed event=\(context.event) toolUseId=\(context.toolUseId) error=\(error.localizedDescription)"
        )
    }
}

private func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return false }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            return false
        }
        return true
    }
}
