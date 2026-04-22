import Foundation

final class PendingResponse: Equatable {
    let timeoutAt: Date
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "com.claude-stats.pending-write")
    private let lock = NSLock()
    private var resolved = false

    init(fd: Int32, timeoutMs: Int) {
        self.fd = fd
        self.timeoutAt = Date(timeIntervalSinceNow: TimeInterval(timeoutMs) / 1000.0)
    }

    func resolve(_ decision: Decision) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let capturedFd = fd
        lock.unlock()

        let payload = "{\"v\":1,\"decision\":\"\(decision.rawValue)\"}\n"
        writeQueue.async {
            guard let data = payload.data(using: .utf8) else { close(capturedFd); return }
            data.withUnsafeBytes { ptr in
                _ = write(capturedFd, ptr.baseAddress, ptr.count)
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
