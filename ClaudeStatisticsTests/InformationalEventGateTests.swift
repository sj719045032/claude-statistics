import XCTest

@testable import Claude_Statistics

final class InformationalEventGateTests: XCTestCase {
    private let key = "claude:s1"

    // MARK: - waiting-input dedup

    func test_wasWaitingShown_falseAtStart() {
        let gate = InformationalEventGate()
        XCTAssertFalse(gate.wasWaitingShown(key: key))
    }

    func test_markAndCheckWaiting() {
        var gate = InformationalEventGate()
        gate.markWaitingShown(key: key)
        XCTAssertTrue(gate.wasWaitingShown(key: key))
    }

    func test_clearWaitingResetsState() {
        var gate = InformationalEventGate()
        gate.markWaitingShown(key: key)
        gate.clearWaitingShown(key: key)
        XCTAssertFalse(gate.wasWaitingShown(key: key))
    }

    func test_distinctKeysIndependent() {
        var gate = InformationalEventGate()
        gate.markWaitingShown(key: "claude:s1")
        XCTAssertFalse(gate.wasWaitingShown(key: "claude:s2"))
        XCTAssertFalse(gate.wasWaitingShown(key: "codex:s1"))
    }

    func test_clearOneKeyKeepsOthers() {
        var gate = InformationalEventGate()
        gate.markWaitingShown(key: "claude:s1")
        gate.markWaitingShown(key: "claude:s2")
        gate.clearWaitingShown(key: "claude:s1")
        XCTAssertFalse(gate.wasWaitingShown(key: "claude:s1"))
        XCTAssertTrue(gate.wasWaitingShown(key: "claude:s2"))
    }

    // MARK: - rate-limit window

    func test_rateLimit_falseAtStart() {
        let gate = InformationalEventGate()
        XCTAssertFalse(gate.isWithinRateLimitWindow(key: key))
    }

    func test_rateLimit_trueRightAfterRecord() {
        var gate = InformationalEventGate()
        let recordedAt = Date(timeIntervalSince1970: 1000)
        gate.recordInformational(key: key, at: recordedAt)
        // 5 seconds later — within 30s window.
        let later = recordedAt.addingTimeInterval(5)
        XCTAssertTrue(gate.isWithinRateLimitWindow(key: key, now: later))
    }

    func test_rateLimit_falseAfterWindow() {
        var gate = InformationalEventGate()
        let recordedAt = Date(timeIntervalSince1970: 1000)
        gate.recordInformational(key: key, at: recordedAt)
        let later = recordedAt.addingTimeInterval(31)
        XCTAssertFalse(gate.isWithinRateLimitWindow(key: key, now: later))
    }

    func test_rateLimit_boundaryAtExactly30sFalse() {
        var gate = InformationalEventGate()
        let recordedAt = Date(timeIntervalSince1970: 1000)
        gate.recordInformational(key: key, at: recordedAt)
        let later = recordedAt.addingTimeInterval(30)
        XCTAssertFalse(gate.isWithinRateLimitWindow(key: key, now: later), "30s exactly is at-or-past boundary")
    }

    func test_rateLimit_customWindow() {
        var gate = InformationalEventGate()
        let recordedAt = Date(timeIntervalSince1970: 1000)
        gate.recordInformational(key: key, at: recordedAt)
        let later = recordedAt.addingTimeInterval(5)
        XCTAssertFalse(gate.isWithinRateLimitWindow(key: key, now: later, window: 1))
    }

    func test_rateLimit_overwriteUpdatesTimestamp() {
        var gate = InformationalEventGate()
        let first = Date(timeIntervalSince1970: 1000)
        let second = Date(timeIntervalSince1970: 1000 + 25)
        gate.recordInformational(key: key, at: first)
        gate.recordInformational(key: key, at: second)
        // 6 seconds after `second` — still inside window from second, NOT
        // counting from first (first+31s would be outside).
        let later = second.addingTimeInterval(6)
        XCTAssertTrue(gate.isWithinRateLimitWindow(key: key, now: later))
    }

    func test_rateLimit_distinctKeysIndependent() {
        var gate = InformationalEventGate()
        let recordedAt = Date(timeIntervalSince1970: 1000)
        gate.recordInformational(key: "claude:s1", at: recordedAt)
        let later = recordedAt.addingTimeInterval(5)
        XCTAssertFalse(gate.isWithinRateLimitWindow(key: "claude:s2", now: later))
    }

    // MARK: - key generation

    func test_keyForEvent_withSessionId() {
        let event = makeEvent(provider: .claude, sessionId: "s1")
        XCTAssertEqual(InformationalEventGate.key(for: event), "claude:s1")
    }

    func test_keyForEvent_emptySessionIdReturnsNil() {
        let event = makeEvent(provider: .claude, sessionId: "")
        XCTAssertNil(InformationalEventGate.key(for: event))
    }

    func test_keyForEvent_providerEncodedInKey() {
        let claude = makeEvent(provider: .claude, sessionId: "s1")
        let codex = makeEvent(provider: .codex, sessionId: "s1")
        XCTAssertNotEqual(InformationalEventGate.key(for: claude), InformationalEventGate.key(for: codex))
    }

    private func makeEvent(provider: ProviderKind, sessionId: String) -> AttentionEvent {
        AttentionEvent(
            id: UUID(),
            provider: provider,
            rawEventName: "Pulse",
            notificationType: nil,
            toolName: nil,
            toolInput: nil,
            toolUseId: nil,
            toolResponse: nil,
            message: nil,
            sessionId: sessionId,
            projectPath: nil,
            transcriptPath: nil,
            tty: nil,
            pid: nil,
            terminalName: nil,
            terminalSocket: nil,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            receivedAt: Date(),
            promptText: nil,
            commentaryText: nil,
            commentaryAt: nil,
            kind: .activityPulse,
            pending: nil
        )
    }
}
