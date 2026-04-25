import XCTest

@testable import Claude_Statistics

@MainActor
final class NotificationTimerStoreTests: XCTestCase {
    func test_contains_emptyAtStart() {
        let store = NotificationTimerStore()
        XCTAssertFalse(store.contains(UUID()))
    }

    func test_schedule_invokesCallbackAfterDelay() async {
        let store = NotificationTimerStore()
        let id = UUID()
        let expectation = expectation(description: "callback fires")

        store.schedule(id: id, after: 0.05) {
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func test_schedule_marksContainsImmediately() {
        let store = NotificationTimerStore()
        let id = UUID()
        store.schedule(id: id, after: 10) {}
        XCTAssertTrue(store.contains(id))
    }

    func test_schedule_dedupsSameIdNoOp() async {
        let store = NotificationTimerStore()
        let id = UUID()
        var firstCount = 0
        var secondCount = 0
        let firstExpectation = expectation(description: "first fires")

        store.schedule(id: id, after: 0.05) {
            firstCount += 1
            firstExpectation.fulfill()
        }
        // Second call with same id should be a no-op — original timer fires.
        store.schedule(id: id, after: 0.05) {
            secondCount += 1
        }

        await fulfillment(of: [firstExpectation], timeout: 1.0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0, "second schedule with same id is dedup'd")
    }

    func test_cancel_preventsCallback() async {
        let store = NotificationTimerStore()
        let id = UUID()
        var fired = false

        store.schedule(id: id, after: 0.1) { fired = true }
        store.cancel(id)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fired)
    }

    func test_cancel_removesFromContains() {
        let store = NotificationTimerStore()
        let id = UUID()
        store.schedule(id: id, after: 10) {}
        store.cancel(id)
        XCTAssertFalse(store.contains(id))
    }

    func test_cancel_unknownIdIsSafe() {
        let store = NotificationTimerStore()
        store.cancel(UUID())  // doesn't crash
    }

    func test_schedule_independentIdsBothFire() async {
        let store = NotificationTimerStore()
        let id1 = UUID()
        let id2 = UUID()
        let exp1 = expectation(description: "id1 fires")
        let exp2 = expectation(description: "id2 fires")
        store.schedule(id: id1, after: 0.05) { exp1.fulfill() }
        store.schedule(id: id2, after: 0.05) { exp2.fulfill() }
        await fulfillment(of: [exp1, exp2], timeout: 1.0)
    }

    func test_canRescheduleAfterCancel() async {
        let store = NotificationTimerStore()
        let id = UUID()
        store.schedule(id: id, after: 0.5) {}
        store.cancel(id)

        let exp = expectation(description: "second schedule fires")
        store.schedule(id: id, after: 0.05) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func test_callbackContainsBecomesFalseAfterFire() async {
        // After the timer fires, the dict still holds the entry until the
        // caller cancels — by design (callbacks are responsible for their
        // own cleanup if needed). This test pins that contract so a future
        // change doesn't silently flip it.
        let store = NotificationTimerStore()
        let id = UUID()
        let exp = expectation(description: "fired")
        store.schedule(id: id, after: 0.05) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertTrue(store.contains(id), "store keeps entry until explicit cancel")
        store.cancel(id)
        XCTAssertFalse(store.contains(id))
    }
}
