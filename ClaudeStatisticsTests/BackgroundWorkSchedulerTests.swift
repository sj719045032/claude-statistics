import XCTest

@testable import Claude_Statistics

final class BackgroundWorkSchedulerTests: XCTestCase {
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    func testAllProvidersShareConcurrencyAndMemoryBudget() async throws {
        let scheduler = BackgroundWorkScheduler(concurrency: 2, byteBudget: 100)
        let snapshots = try await withThrowingTaskGroup(of: BackgroundWorkScheduler.Snapshot.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    try await scheduler.run(estimatedBytes: 60) {
                        let snapshot = await scheduler.snapshot
                        try await Task.sleep(for: .milliseconds(2))
                        return snapshot
                    }
                }
            }
            var values: [BackgroundWorkScheduler.Snapshot] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(snapshots.count, 30)
        XCTAssertTrue(snapshots.allSatisfy { $0.running == 1 && $0.reservedBytes == 60 })
        let final = await scheduler.snapshot
        XCTAssertEqual(final.running, 0)
        XCTAssertEqual(final.waiting, 0)
        XCTAssertEqual(final.reservedBytes, 0)
    }

    func testOversizedFilesRunAloneWithoutDeadlock() async throws {
        let scheduler = BackgroundWorkScheduler(concurrency: 2, byteBudget: 100)
        let result = try await scheduler.run(estimatedBytes: 1_000) {
            await scheduler.snapshot
        }
        XCTAssertEqual(result.running, 1)
        XCTAssertEqual(result.reservedBytes, 1_000)
        let next = try await scheduler.run(estimatedBytes: 10) { 42 }
        XCTAssertEqual(next, 42)
    }

    func testCancelledWaiterDoesNotRunOrLeakCapacity() async throws {
        let scheduler = BackgroundWorkScheduler(concurrency: 1)
        let gate = Gate()
        let started = expectation(description: "first operation started")
        let first = Task {
            try await scheduler.run {
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let next = Task {
            try await scheduler.run {
                XCTFail("Cancelled queued work must not run")
            }
        }
        next.cancel()
        do {
            try await next.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
        await gate.open()
        try await first.value
        let final = await scheduler.snapshot
        XCTAssertEqual(final.running, 0)
        XCTAssertEqual(final.waiting, 0)
    }

    func testThrownOperationReleasesItsSlot() async throws {
        enum Failure: Error { case expected }
        let scheduler = BackgroundWorkScheduler(concurrency: 1)
        do {
            let _: Int = try await scheduler.run { throw Failure.expected }
            XCTFail("Expected failure")
        } catch Failure.expected {}
        let next = try await scheduler.run { 42 }
        XCTAssertEqual(next, 42)
    }

    func testCancelledNonCooperativeOperationIsDiscardedAfterDraining() async throws {
        let scheduler = BackgroundWorkScheduler(concurrency: 1, byteBudget: 100)
        let gate = Gate()
        let started = expectation(description: "operation started")
        let task = Task {
            try await scheduler.run(estimatedBytes: 80) {
                started.fulfill()
                await gate.wait()
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let draining = await scheduler.snapshot
        XCTAssertEqual(draining.running, 1)
        XCTAssertEqual(draining.reservedBytes, 80)
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("A cancelled plugin's result must not escape the scheduler")
        } catch is CancellationError {}
        let next = try await scheduler.run(estimatedBytes: 100) { await scheduler.snapshot }
        XCTAssertEqual(next.running, 1)
        XCTAssertEqual(next.reservedBytes, 100)
    }
}
