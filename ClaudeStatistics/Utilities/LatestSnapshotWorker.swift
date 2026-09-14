import Foundation

/// One running calculation and at most one pending snapshot. A replacement
/// waits for cancelled work to finish, even when legacy code ignores cancel.
@MainActor
final class LatestSnapshotWorker<Input: Sendable, Output: Sendable> {
    private let compute: @Sendable (Input) async throws -> Output
    private let publish: @MainActor (Output) -> Void
    private var task: Task<Void, Never>?
    private var pending: Input?
    private var revision: UInt64 = 0

    var isWorking: Bool { task != nil || pending != nil }

    init(compute: @escaping @Sendable (Input) async throws -> Output,
         publish: @escaping @MainActor (Output) -> Void) {
        self.compute = compute
        self.publish = publish
    }

    deinit { task?.cancel() }

    func submit(_ input: Input) {
        revision &+= 1
        pending = input
        startNext()
    }

    func cancel() {
        revision &+= 1
        pending = nil
        task?.cancel()
    }

    private func startNext() {
        guard task == nil, let input = pending else { return }
        pending = nil
        let currentRevision = revision
        let compute = compute
        task = Task.detached(priority: .utility) { [weak self] in
            let value = try? await compute(input)
            let cancelled = Task.isCancelled
            await self?.finish(value, revision: currentRevision, cancelled: cancelled)
        }
    }

    private func finish(_ output: Output?, revision completedRevision: UInt64, cancelled: Bool) {
        task = nil
        if !cancelled, completedRevision == revision, let output { publish(output) }
        startNext()
    }
}
