import Foundation

/// One budget for expensive session work across every provider. Awaiting a slot
/// suspends the task rather than blocking a thread. An oversized file runs alone.
actor BackgroundWorkScheduler {
    static let shared = BackgroundWorkScheduler()

    enum Priority: Int, Sendable {
        case interactive
        case background
    }

    struct Snapshot: Sendable {
        let running: Int
        let waiting: Int
        let reservedBytes: Int64
    }

    private struct Waiter {
        let id: UUID
        let bytes: Int64
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }

    private let concurrency: Int
    private let byteBudget: Int64
    private var running = 0
    private var reservedBytes: Int64 = 0
    private var waiters: [Waiter] = []

    init(concurrency: Int = 2, byteBudget: Int64 = 128 * 1024 * 1024) {
        precondition(concurrency > 0 && byteBudget > 0)
        self.concurrency = concurrency
        self.byteBudget = byteBudget
    }

    var snapshot: Snapshot {
        Snapshot(running: running, waiting: waiters.count, reservedBytes: reservedBytes)
    }

    func run<T: Sendable>(estimatedBytes: Int64 = 1, priority: Priority = .background,
                          operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let bytes = max(1, estimatedBytes)
        return try await withTaskCancellationHandler {
            try await acquire(id: id, bytes: bytes, priority: priority)
            defer { release(bytes: bytes) }
            try Task.checkCancellation()
            let result = try await operation()
            // Older plugins may finish synchronous work after cancellation.
            // Keep its reservation until it returns, but never accept the result.
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancelWaiting(id: id) }
        }
    }

    private func acquire(id: UUID, bytes: Int64, priority: Priority) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, bytes: bytes, priority: priority, continuation: continuation))
            drain()
        }
    }

    private func cancelWaiting(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }

    private func release(bytes: Int64) {
        running -= 1
        reservedBytes -= bytes
        drain()
    }

    private func drain() {
        while running < concurrency, !waiters.isEmpty {
            // FIFO within a priority. Don't skip a large pending job forever
            // by filling its budget with newer, smaller jobs.
            let index = waiters.firstIndex(where: { $0.priority == .interactive }) ?? 0
            let next = waiters[index]
            guard running == 0 || next.bytes <= byteBudget - reservedBytes else { return }
            waiters.remove(at: index)
            running += 1
            reservedBytes += next.bytes
            next.continuation.resume()
        }
    }
}
