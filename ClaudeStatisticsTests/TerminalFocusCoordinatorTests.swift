import XCTest

@testable import Claude_Statistics

final class TerminalFocusCoordinatorTests: XCTestCase {
    private let sessionPid: Int32 = 4242
    private let terminalGUIPid: pid_t = 99

    func test_frontmostMatchesSession_matchesTerminalBundleInFront() {
        // The regression this guards: a terminal with no AppleScript
        // prober (Termius / Kitty / WezTerm / Alacritty / Warp) is the
        // frontmost app, so focus-silence must fire even though the
        // session pid belongs to the CLI, not the GUI app.
        XCTAssertTrue(
            TerminalFocusCoordinator.frontmostMatchesSession(
                frontmostBundleId: "com.termius-dmg.mac",
                frontmostPid: terminalGUIPid,
                terminalBundleId: "com.termius-dmg.mac",
                sessionPid: sessionPid
            )
        )
    }

    func test_frontmostMatchesSession_doesNotMatchOtherAppInFront() {
        XCTAssertFalse(
            TerminalFocusCoordinator.frontmostMatchesSession(
                frontmostBundleId: "com.apple.finder",
                frontmostPid: terminalGUIPid,
                terminalBundleId: "com.termius-dmg.mac",
                sessionPid: sessionPid
            )
        )
    }

    func test_frontmostMatchesSession_stillMatchesOnPidForGUIHosts() {
        // Chat-app hosts that report their own pid keep the pre-existing
        // behaviour even when the bundle id is unknown.
        XCTAssertTrue(
            TerminalFocusCoordinator.frontmostMatchesSession(
                frontmostBundleId: "com.anthropic.claudefordesktop",
                frontmostPid: sessionPid,
                terminalBundleId: nil,
                sessionPid: sessionPid
            )
        )
    }

    func test_frontmostMatchesSession_unresolvedTerminalWithMismatchedPid() {
        XCTAssertFalse(
            TerminalFocusCoordinator.frontmostMatchesSession(
                frontmostBundleId: "com.apple.finder",
                frontmostPid: terminalGUIPid,
                terminalBundleId: nil,
                sessionPid: sessionPid
            )
        )
    }

    func test_frontmostMatchesSession_noFrontmostAppIsNotFocused() {
        XCTAssertFalse(
            TerminalFocusCoordinator.frontmostMatchesSession(
                frontmostBundleId: nil,
                frontmostPid: nil,
                terminalBundleId: "com.termius-dmg.mac",
                sessionPid: sessionPid
            )
        )
    }

    func test_frontmostMatchesSession_noSessionPidFallsBackToBundleOnly() {
        XCTAssertTrue(
            TerminalFocusCoordinator.frontmostMatchesSession(
                frontmostBundleId: "net.kovidgoyal.kitty",
                frontmostPid: terminalGUIPid,
                terminalBundleId: "net.kovidgoyal.kitty",
                sessionPid: nil
            )
        )
        XCTAssertFalse(
            TerminalFocusCoordinator.frontmostMatchesSession(
                frontmostBundleId: "com.apple.finder",
                frontmostPid: terminalGUIPid,
                terminalBundleId: "net.kovidgoyal.kitty",
                sessionPid: nil
            )
        )
    }
}
