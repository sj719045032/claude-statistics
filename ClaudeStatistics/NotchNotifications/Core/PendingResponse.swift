import Darwin
import Foundation
import ClaudeStatisticsKit

final class PendingResponse: Equatable {
    let timeoutAt: Date
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "com.claude-stats.pending-write")
    private let lock = NSLock()
    private var resolved = false

    init(fd: Int32, timeoutMs: Int) {
        self.fd = fd
        self.timeoutAt = Date(timeIntervalSinceNow: TimeInterval(timeoutMs) / 1000.0)

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    func resolve(_ decision: Decision) {
        resolve(payload: PendingResponsePayload(decision: decision.rawValue, updatedInput: nil))
    }

    func answerAskUserQuestion(updatedInput: [String: JSONValue]) {
        resolve(payload: PendingResponsePayload(decision: Decision.allow.rawValue, updatedInput: updatedInput))
    }

    private func resolve(payload: PendingResponsePayload) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let capturedFd = fd
        lock.unlock()

        writeQueue.async {
            guard let data = try? JSONEncoder().encode(payload) else {
                close(capturedFd)
                return
            }
            let framedData = data + Data([0x0A])
            let wroteAllBytes = framedData.withUnsafeBytes { ptr -> Bool in
                guard let baseAddress = ptr.baseAddress else { return false }
                let written = write(capturedFd, baseAddress, ptr.count)
                if written < 0 {
                    let code = errno
                    DiagnosticLogger.shared.warning(
                        "PendingResponse write failed fd=\(capturedFd) errno=\(code) decision=\(payload.decision)"
                    )
                    return false
                }
                return written == framedData.count
            }
            if !wroteAllBytes {
                DiagnosticLogger.shared.warning(
                    "PendingResponse write incomplete fd=\(capturedFd) decision=\(payload.decision)"
                )
            }
            close(capturedFd)
        }
    }

    func timeout() { resolve(.ask) }

    deinit {
        lock.lock()
        let wasResolved = resolved
        lock.unlock()
        if !wasResolved { close(fd) }
    }

    static func == (lhs: PendingResponse, rhs: PendingResponse) -> Bool {
        lhs === rhs
    }
}

private struct PendingResponsePayload: Encodable {
    let v = 1
    let decision: String
    let updatedInput: [String: JSONValue]?
}
