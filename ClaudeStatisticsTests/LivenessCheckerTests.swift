import Darwin
import Foundation
import XCTest

@testable import Claude_Statistics

final class LivenessCheckerTests: XCTestCase {

    // MARK: - isProcessAlive

    func test_isProcessAlive_currentProcess() {
        XCTAssertTrue(LivenessChecker.isProcessAlive(getpid()), "current pid is alive")
    }

    func test_isProcessAlive_launchd() {
        // PID 1 is launchd on macOS. kill(1, 0) returns EPERM for non-root,
        // which the implementation treats as alive.
        XCTAssertTrue(LivenessChecker.isProcessAlive(1), "launchd (pid 1) is alive")
    }

    func test_isProcessAlive_nonexistentPid() {
        let bogus: Int32 = getpid() &+ 1_000_000
        XCTAssertFalse(LivenessChecker.isProcessAlive(bogus), "bogus pid is not alive")
    }

    // MARK: - isProcessStopped

    func test_isProcessStopped_currentProcessIsRunning() {
        XCTAssertFalse(LivenessChecker.isProcessStopped(getpid()), "current process is not stopped")
    }

    func test_isProcessStopped_nonexistentPidReturnsFalse() {
        let bogus: Int32 = getpid() &+ 1_000_000
        XCTAssertFalse(LivenessChecker.isProcessStopped(bogus), "lookup failure returns false to avoid eviction")
    }

    // MARK: - isTerminalContextAlive

    func test_isTerminalContextAlive_bothNilIsConservativelyAlive() {
        XCTAssertTrue(
            LivenessChecker.isTerminalContextAlive(tty: nil, terminalSocket: nil),
            "both nil falls through to conservative true"
        )
    }

    func test_isTerminalContextAlive_bothEmptyIsConservativelyAlive() {
        // Empty strings fail the !isEmpty guard on each branch and fall
        // through to the conservative tail return.
        XCTAssertTrue(
            LivenessChecker.isTerminalContextAlive(tty: "", terminalSocket: ""),
            "empty strings fall through to conservative true"
        )
    }

    func test_isTerminalContextAlive_existingTty() {
        // /dev/null always exists on macOS.
        XCTAssertTrue(
            LivenessChecker.isTerminalContextAlive(tty: "/dev/null", terminalSocket: nil),
            "/dev/null is an existing path"
        )
    }

    func test_isTerminalContextAlive_missingTty() {
        let path = "/some/path/that/definitely/does/not/exist/__test__"
        XCTAssertFalse(
            LivenessChecker.isTerminalContextAlive(tty: path, terminalSocket: nil),
            "missing tty path returns false"
        )
    }

    func test_isTerminalContextAlive_existingSocketWhenTtyNil() throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("liveness-socket-\(UUID().uuidString)")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: path, contents: Data()),
            "create temp socket-stand-in file"
        )
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(
            LivenessChecker.isTerminalContextAlive(tty: nil, terminalSocket: path),
            "existing terminalSocket path returns true"
        )
    }

    func test_isTerminalContextAlive_missingSocketWhenTtyNil() {
        let path = "/var/folders/__nope__/liveness-test-missing-\(UUID().uuidString)"
        XCTAssertFalse(
            LivenessChecker.isTerminalContextAlive(tty: nil, terminalSocket: path),
            "missing terminalSocket path returns false"
        )
    }

    // MARK: - shouldKeepSession

    func test_shouldKeepSession_recentActivity_noPid_keeps() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-30) // recent, > cutoff
        XCTAssertTrue(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: nil,
                tty: nil,
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "recent activity keeps session even with no pid"
        )
    }

    func test_shouldKeepSession_staleActivity_noPid_drops() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-600) // older than cutoff
        XCTAssertFalse(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: nil,
                tty: nil,
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "stale activity with no pid drops"
        )
    }

    func test_shouldKeepSession_staleActivity_livePid_existingTty_keeps() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-600)
        XCTAssertTrue(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: getpid(),
                tty: "/dev/null",
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "stale + live pid + existing tty keeps"
        )
    }

    func test_shouldKeepSession_staleActivity_livePid_missingTty_drops() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-600)
        XCTAssertFalse(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: getpid(),
                tty: "/some/path/that/definitely/does/not/exist/__test__",
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "stale + live pid + missing tty drops"
        )
    }

    func test_shouldKeepSession_staleActivity_deadPid_drops() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-600)
        let bogus: Int32 = getpid() &+ 1_000_000
        XCTAssertFalse(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: bogus,
                tty: "/dev/null",
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "stale + dead pid drops via 10s liveness check"
        )
    }

    func test_shouldKeepSession_oldButOutsideGrace_deadPid_drops() {
        // 11s since last activity, dead pid → first branch evicts.
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-11)
        let bogus: Int32 = getpid() &+ 1_000_000
        XCTAssertFalse(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: bogus,
                tty: nil,
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "11s since last activity with dead pid drops"
        )
    }

    func test_shouldKeepSession_withinGrace_deadPid_keeps() {
        // 5s since last activity (< 10s grace) with dead pid → first branch
        // skipped, then lastActivityAt > cutoff so it keeps.
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-5)
        let bogus: Int32 = getpid() &+ 1_000_000
        XCTAssertTrue(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: bogus,
                tty: nil,
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "within 10s grace + recent activity keeps even with dead pid"
        )
    }

    func test_shouldKeepSession_pidZero_treatedAsNoPid_staleDrops() {
        // pid == 0 fails the `pid > 0` guards, so stale activity drops.
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let last = now.addingTimeInterval(-600)
        XCTAssertFalse(
            LivenessChecker.shouldKeepSession(
                provider: .claude,
                lastActivityAt: last,
                pid: 0,
                tty: "/dev/null",
                terminalSocket: nil,
                cutoff: cutoff,
                now: now
            ),
            "pid==0 treated like nil; stale activity drops"
        )
    }
}
