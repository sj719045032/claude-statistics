import XCTest

@testable import Claude_Statistics

@MainActor
final class LatestSnapshotWorkerTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testBurstRunsFirstAndLatestOnlyAndPublishesLatest() async {
        let gate = Gate()
        let firstStarted = expectation(description: "first snapshot started")
        let latestFinished = expectation(description: "latest snapshot published")
        var published: [Int] = []
        let worker = LatestSnapshotWorker<Int, Int>(compute: { value in
            if value == 1 {
                firstStarted.fulfill()
                await gate.wait()
            } else {
                XCTAssertEqual(value, 100, "Intermediate snapshots must be coalesced")
            }
            return value
        }, publish: { value in
            published.append(value)
            latestFinished.fulfill()
        })
        worker.submit(1)
        await fulfillment(of: [firstStarted], timeout: 2)
        for value in 2...100 { worker.submit(value) }
        await gate.open()
        await fulfillment(of: [latestFinished], timeout: 2)
        XCTAssertEqual(published, [100])
        XCTAssertFalse(worker.isWorking)
    }

    func testCancelThenRestartWaitsForOldWorkAndRejectsOldResult() async {
        let gate = Gate()
        let firstStarted = expectation(description: "first started")
        let finished = expectation(description: "replacement published")
        var published: [Int] = []
        let worker = LatestSnapshotWorker<Int, Int>(compute: { value in
            if value == 1 {
                firstStarted.fulfill()
                await gate.wait() // Old plugin code may ignore cancellation.
            }
            return value
        }, publish: { value in
            published.append(value)
            finished.fulfill()
        })
        worker.submit(1)
        await fulfillment(of: [firstStarted], timeout: 2)
        worker.cancel()
        worker.submit(2)
        XCTAssertTrue(worker.isWorking)
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(published, [2])
    }
}
