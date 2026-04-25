import Foundation
import XCTest

@testable import Claude_Statistics

final class TerminalIdentityResolverTests: XCTestCase {

    // MARK: - Factories

    /// Build a RuntimeSession via JSONDecoder so we don't have to track every
    /// non-Optional stored property's default in the synthesized memberwise
    /// init. Mirrors the approach in `RuntimeStatePersistorTests.makeSession`.
    private func makeRuntime(
        provider: ProviderKind = .claude,
        sessionId: String = "session",
        lastActivityAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        latestPreview: String? = nil,
        tty: String? = nil,
        terminalName: String? = nil,
        terminalWindowID: String? = nil,
        terminalTabID: String? = nil,
        terminalStableID: String? = nil,
        approvalToolName: String? = nil,
        approvalToolDetail: String? = nil,
        approvalStartedAt: Date? = nil,
        approvalToolUseId: String? = nil
    ) -> RuntimeSession {
        var json: [String: Any] = [
            "provider": provider.rawValue,
            "sessionId": sessionId,
            "lastActivityAt": lastActivityAt.timeIntervalSinceReferenceDate,
            "status": "idle",
            "backgroundShellCount": 0,
            "activeSubagentCount": 0,
            "activeTools": [String: Any](),
            "recentlyCompletedTools": [Any]()
        ]
        if let latestPreview { json["latestPreview"] = latestPreview }
        if let tty { json["tty"] = tty }
        if let terminalName { json["terminalName"] = terminalName }
        if let terminalWindowID { json["terminalWindowID"] = terminalWindowID }
        if let terminalTabID { json["terminalTabID"] = terminalTabID }
        if let terminalStableID { json["terminalStableID"] = terminalStableID }
        if let approvalToolName { json["approvalToolName"] = approvalToolName }
        if let approvalToolDetail { json["approvalToolDetail"] = approvalToolDetail }
        if let approvalStartedAt { json["approvalStartedAt"] = approvalStartedAt.timeIntervalSinceReferenceDate }
        if let approvalToolUseId { json["approvalToolUseId"] = approvalToolUseId }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(RuntimeSession.self, from: data)
    }

    private func makeEvent(
        provider: ProviderKind = .claude,
        sessionId: String = "evt-session",
        tty: String? = nil,
        terminalName: String? = nil,
        terminalTabID: String? = nil,
        terminalStableID: String? = nil
    ) -> AttentionEvent {
        AttentionEvent(
            id: UUID(),
            provider: provider,
            rawEventName: "SessionStart",
            notificationType: nil,
            toolName: nil,
            toolInput: nil,
            toolUseId: nil,
            toolResponse: nil,
            message: nil,
            sessionId: sessionId,
            projectPath: nil,
            transcriptPath: nil,
            tty: tty,
            pid: nil,
            terminalName: terminalName,
            terminalSocket: nil,
            terminalWindowID: nil,
            terminalTabID: terminalTabID,
            terminalStableID: terminalStableID,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            promptText: nil,
            commentaryText: nil,
            commentaryAt: nil,
            kind: .sessionStart(source: nil),
            pending: nil
        )
    }

    // MARK: - sanitized

    func test_sanitized_genericWaitingPreviewIsCleared() {
        let runtime = makeRuntime(latestPreview: "Awaiting your input")
        let result = TerminalIdentityResolver.sanitized(runtime)
        XCTAssertNil(result.latestPreview, "generic 'Awaiting your input' preview should be cleared")
    }

    func test_sanitized_genericWaitingPreviewMixedCaseIsCleared() {
        let runtime = makeRuntime(latestPreview: "  AWAITING Your Input  ")
        let result = TerminalIdentityResolver.sanitized(runtime)
        XCTAssertNil(result.latestPreview, "case + whitespace variants are still recognized as generic")
    }

    func test_sanitized_nonGenericPreviewIsKept() {
        let runtime = makeRuntime(latestPreview: "Run Bash command?")
        let result = TerminalIdentityResolver.sanitized(runtime)
        XCTAssertEqual(result.latestPreview, "Run Bash command?", "non-generic preview text should survive sanitization")
    }

    func test_sanitized_nilPreviewStaysNil() {
        let runtime = makeRuntime(latestPreview: nil)
        let result = TerminalIdentityResolver.sanitized(runtime)
        XCTAssertNil(result.latestPreview)
    }

    func test_sanitized_staleApprovalIsCleared() {
        let staleStarted = Date().addingTimeInterval(-(ActiveSession.approvalStaleInterval + 1))
        let runtime = makeRuntime(
            approvalToolName: "Bash",
            approvalToolDetail: "ls /",
            approvalStartedAt: staleStarted,
            approvalToolUseId: "tool-use-1"
        )
        let result = TerminalIdentityResolver.sanitized(runtime)

        XCTAssertNil(result.approvalToolName, "stale approvalToolName should be cleared")
        XCTAssertNil(result.approvalToolDetail, "stale approvalToolDetail should be cleared")
        XCTAssertNil(result.approvalStartedAt, "stale approvalStartedAt should be cleared")
        XCTAssertNil(result.approvalToolUseId, "stale approvalToolUseId should be cleared")
    }

    func test_sanitized_freshApprovalIsKept() {
        let freshStarted = Date().addingTimeInterval(-1)
        let runtime = makeRuntime(
            approvalToolName: "Bash",
            approvalToolDetail: "ls /",
            approvalStartedAt: freshStarted,
            approvalToolUseId: "tool-use-1"
        )
        let result = TerminalIdentityResolver.sanitized(runtime)

        XCTAssertEqual(result.approvalToolName, "Bash", "fresh approval should be preserved")
        XCTAssertEqual(result.approvalToolDetail, "ls /")
        XCTAssertNotNil(result.approvalStartedAt)
        XCTAssertEqual(result.approvalToolUseId, "tool-use-1")
    }

    // MARK: - sanitizedGhosttyCollisions

    func test_sanitizedGhosttyCollisions_emptyDictReturnsEmpty() {
        let result = TerminalIdentityResolver.sanitizedGhosttyCollisions([:])
        XCTAssertTrue(result.isEmpty)
    }

    func test_sanitizedGhosttyCollisions_nonGhosttyEntryUnchanged() {
        let runtime = makeRuntime(
            tty: "/dev/ttys001",
            terminalName: "iTerm2",
            terminalWindowID: "win-1",
            terminalTabID: "tab-1",
            terminalStableID: "stable-1"
        )
        let input = ["k1": runtime]
        let result = TerminalIdentityResolver.sanitizedGhosttyCollisions(input)

        XCTAssertEqual(result["k1"]?.terminalStableID, "stable-1", "non-Ghostty entries are not touched")
        XCTAssertEqual(result["k1"]?.terminalTabID, "tab-1")
        XCTAssertEqual(result["k1"]?.terminalWindowID, "win-1")
    }

    func test_sanitizedGhosttyCollisions_singleGhosttyEntryUnchanged() {
        let runtime = makeRuntime(
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalWindowID: "win-1",
            terminalTabID: "tab-1",
            terminalStableID: "stable-1"
        )
        let result = TerminalIdentityResolver.sanitizedGhosttyCollisions(["k1": runtime])

        XCTAssertEqual(result["k1"]?.terminalStableID, "stable-1", "a lone Ghostty entry has nothing to collide with")
        XCTAssertEqual(result["k1"]?.terminalTabID, "tab-1")
        XCTAssertEqual(result["k1"]?.terminalWindowID, "win-1")
    }

    func test_sanitizedGhosttyCollisions_distinctStableIDsLeftAlone() {
        let a = makeRuntime(
            sessionId: "a",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-A"
        )
        let b = makeRuntime(
            sessionId: "b",
            tty: "/dev/ttys002",
            terminalName: "ghostty",
            terminalStableID: "stable-B"
        )
        let result = TerminalIdentityResolver.sanitizedGhosttyCollisions(["a": a, "b": b])

        XCTAssertEqual(result["a"]?.terminalStableID, "stable-A", "different stableIDs are not a collision")
        XCTAssertEqual(result["b"]?.terminalStableID, "stable-B")
    }

    func test_sanitizedGhosttyCollisions_sameStableIDSameTTYNotConsideredCollision() {
        // Same stableID + same TTY isn't a real ambiguity — there's only one
        // distinct TTY in the group, so the resolver leaves both records alone.
        let a = makeRuntime(
            sessionId: "a",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-shared"
        )
        let b = makeRuntime(
            sessionId: "b",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-shared"
        )
        let result = TerminalIdentityResolver.sanitizedGhosttyCollisions(["a": a, "b": b])

        XCTAssertEqual(result["a"]?.terminalStableID, "stable-shared", "same TTY means no real collision")
        XCTAssertEqual(result["b"]?.terminalStableID, "stable-shared")
    }

    func test_sanitizedGhosttyCollisions_sameStableIDDifferentTTYClearsLoser() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)

        let loser = makeRuntime(
            sessionId: "loser",
            lastActivityAt: older,
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalWindowID: "win-1",
            terminalTabID: "tab-1",
            terminalStableID: "stable-shared"
        )
        let winner = makeRuntime(
            sessionId: "winner",
            lastActivityAt: newer,
            tty: "/dev/ttys002",
            terminalName: "ghostty",
            terminalWindowID: "win-2",
            terminalTabID: "tab-2",
            terminalStableID: "stable-shared"
        )

        let result = TerminalIdentityResolver.sanitizedGhosttyCollisions([
            "loser": loser,
            "winner": winner
        ])

        XCTAssertEqual(result["winner"]?.terminalStableID, "stable-shared", "most-recent activity keeps its identity")
        XCTAssertEqual(result["winner"]?.terminalTabID, "tab-2")
        XCTAssertEqual(result["winner"]?.terminalWindowID, "win-2")

        XCTAssertNil(result["loser"]?.terminalStableID, "older entry has its stableID stripped")
        XCTAssertNil(result["loser"]?.terminalTabID, "older entry has its tabID stripped")
        XCTAssertNil(result["loser"]?.terminalWindowID, "older entry has its windowID stripped")
        XCTAssertEqual(result["loser"]?.tty, "/dev/ttys001", "tty is left alone — focus can fall back to it")
    }

    // MARK: - sessionsDisplaced

    func test_sessionsDisplaced_eventWithNoIdentitiesReturnsEmpty() {
        let runtime = makeRuntime(tty: "/dev/ttys001", terminalName: "iTerm2", terminalTabID: "t1", terminalStableID: "s1")
        let event = makeEvent(terminalName: "iTerm2") // no tty / tabID / stableID
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "new",
            in: ["k1": runtime]
        )
        XCTAssertEqual(displaced.count, 0, "without any terminal identity, displacement must be empty")
    }

    func test_sessionsDisplaced_matchesOnSharedTTY() {
        let runtime = makeRuntime(sessionId: "old", tty: "/dev/ttys001", terminalName: "iTerm2")
        let event = makeEvent(tty: "/dev/ttys001", terminalName: "iTerm2")
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "new",
            in: ["k1": runtime]
        )
        XCTAssertEqual(displaced.count, 1, "shared TTY is the strongest signal")
        XCTAssertEqual(displaced.first?.key, "k1")
        XCTAssertEqual(displaced.first?.sessionId, "old")
    }

    func test_sessionsDisplaced_excludesNewKey() {
        let runtime = makeRuntime(sessionId: "old", tty: "/dev/ttys001", terminalName: "iTerm2")
        let event = makeEvent(tty: "/dev/ttys001", terminalName: "iTerm2")
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "k1",
            in: ["k1": runtime]
        )
        XCTAssertEqual(displaced.count, 0, "the key being installed should not be evicted by itself")
    }

    func test_sessionsDisplaced_nonGhosttySameStableIDMatches() {
        let runtime = makeRuntime(
            sessionId: "old",
            tty: "/dev/ttys001",
            terminalName: "iTerm2",
            terminalStableID: "stable-1"
        )
        let event = makeEvent(
            tty: "/dev/ttys002", // different TTY — doesn't matter for non-Ghostty
            terminalName: "iTerm2",
            terminalStableID: "stable-1"
        )
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "new",
            in: ["k1": runtime]
        )
        XCTAssertEqual(displaced.count, 1, "non-Ghostty terminals can match on stableID across TTYs")
        XCTAssertEqual(displaced.first?.key, "k1")
    }

    func test_sessionsDisplaced_ghosttySameStableIDDifferentTTYDoesNotMatch() {
        let runtime = makeRuntime(
            sessionId: "old",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-shared"
        )
        let event = makeEvent(
            tty: "/dev/ttys002",
            terminalName: "ghostty",
            terminalStableID: "stable-shared"
        )
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "new",
            in: ["k1": runtime]
        )
        XCTAssertEqual(displaced.count, 0, "Ghostty stableID across different TTYs is not a tab match")
    }

    func test_sessionsDisplaced_ghosttySameStableIDSameTTYMatches() {
        let runtime = makeRuntime(
            sessionId: "old",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-shared"
        )
        let event = makeEvent(
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-shared"
        )
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "new",
            in: ["k1": runtime]
        )
        // Note: the TTY branch fires first here (both have the same TTY), but
        // the result is the same — the runtime is displaced.
        XCTAssertEqual(displaced.count, 1, "Ghostty stableID + same TTY still displaces the prior session")
        XCTAssertEqual(displaced.first?.key, "k1")
    }

    func test_sessionsDisplaced_nonGhosttySameTabIDMatches() {
        // tabID-only match: no shared TTY, no shared stableID. Non-Ghostty
        // terminals get to match on tabID.
        let runtime = makeRuntime(
            sessionId: "old",
            tty: "/dev/ttys001",
            terminalName: "iTerm2",
            terminalTabID: "tab-42"
        )
        let event = makeEvent(
            tty: "/dev/ttys002",
            terminalName: "iTerm2",
            terminalTabID: "tab-42"
        )
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "new",
            in: ["k1": runtime]
        )
        XCTAssertEqual(displaced.count, 1, "non-Ghostty tabID is trustworthy enough to displace")
        XCTAssertEqual(displaced.first?.key, "k1")
    }

    func test_sessionsDisplaced_ghosttySameTabIDDoesNotMatch() {
        // Ghostty's tabID alone is unreliable (closed-tab leftovers can claim
        // a new tab's tabID), so the resolver explicitly skips that branch.
        let runtime = makeRuntime(
            sessionId: "old",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalTabID: "tab-42"
        )
        let event = makeEvent(
            tty: "/dev/ttys002",
            terminalName: "ghostty",
            terminalTabID: "tab-42"
        )
        let displaced = TerminalIdentityResolver.sessionsDisplaced(
            by: event,
            excludingKey: "new",
            in: ["k1": runtime]
        )
        XCTAssertEqual(displaced.count, 0, "Ghostty tabID is untrustworthy and must not displace on its own")
    }

    // MARK: - acceptsTerminalIdentity

    func test_acceptsTerminalIdentity_nonGhosttyAlwaysAccepted() {
        // Even with a perfect collision on iTerm2, the non-Ghostty path bails
        // out early and accepts.
        let other = makeRuntime(
            sessionId: "other",
            tty: "/dev/ttys001",
            terminalName: "iTerm2",
            terminalStableID: "stable-1"
        )
        let accepted = TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: "new",
            terminalName: "iTerm2",
            incomingTTY: "/dev/ttys002",
            incomingTabID: nil,
            incomingStableID: "stable-1",
            in: ["other": other]
        )
        XCTAssertTrue(accepted, "non-Ghostty terminals always accept their own identity")
    }

    func test_acceptsTerminalIdentity_ghosttyWithoutStableOrTabIDAccepted() {
        let other = makeRuntime(
            sessionId: "other",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-1"
        )
        let accepted = TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: "new",
            terminalName: "ghostty",
            incomingTTY: "/dev/ttys002",
            incomingTabID: nil,
            incomingStableID: nil,
            in: ["other": other]
        )
        XCTAssertTrue(accepted, "no stableID/tabID means there's nothing to collide on")
    }

    func test_acceptsTerminalIdentity_ghosttyWithoutTTYAccepted() {
        let other = makeRuntime(
            sessionId: "other",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-1"
        )
        let accepted = TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: "new",
            terminalName: "ghostty",
            incomingTTY: nil,
            incomingTabID: nil,
            incomingStableID: "stable-1",
            in: ["other": other]
        )
        XCTAssertTrue(accepted, "without an incoming TTY we can't compare against the existing record")
    }

    func test_acceptsTerminalIdentity_ghosttySameStableIDDifferentTTYRejected() {
        let other = makeRuntime(
            sessionId: "other",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-1"
        )
        let accepted = TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: "new",
            terminalName: "ghostty",
            incomingTTY: "/dev/ttys002",
            incomingTabID: nil,
            incomingStableID: "stable-1",
            in: ["other": other]
        )
        XCTAssertFalse(accepted, "two Ghostty surfaces claiming the same stableID via different TTYs must reject")
    }

    func test_acceptsTerminalIdentity_ghosttySameTabIDDifferentTTYRejected() {
        // No incoming stableID — the tabID-collision branch should fire.
        let other = makeRuntime(
            sessionId: "other",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalTabID: "tab-1"
        )
        let accepted = TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: "new",
            terminalName: "ghostty",
            incomingTTY: "/dev/ttys002",
            incomingTabID: "tab-1",
            incomingStableID: nil,
            in: ["other": other]
        )
        XCTAssertFalse(accepted, "tabID collision with different TTY also rejects")
    }

    func test_acceptsTerminalIdentity_ghosttyMatchingRuntimeIsSelfAccepted() {
        // If the colliding runtime IS the key being checked, it's not a real
        // collision — the loop skips own key.
        let selfRuntime = makeRuntime(
            sessionId: "self",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-1"
        )
        let accepted = TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: "self",
            terminalName: "ghostty",
            incomingTTY: "/dev/ttys002",
            incomingTabID: nil,
            incomingStableID: "stable-1",
            in: ["self": selfRuntime]
        )
        XCTAssertTrue(accepted, "the key under test is excluded from collision checks")
    }

    func test_acceptsTerminalIdentity_ghosttyNoCollisionAccepted() {
        let other = makeRuntime(
            sessionId: "other",
            tty: "/dev/ttys001",
            terminalName: "ghostty",
            terminalStableID: "stable-other"
        )
        let accepted = TerminalIdentityResolver.acceptsTerminalIdentity(
            forKey: "new",
            terminalName: "ghostty",
            incomingTTY: "/dev/ttys002",
            incomingTabID: "tab-incoming",
            incomingStableID: "stable-incoming",
            in: ["other": other]
        )
        XCTAssertTrue(accepted, "no overlapping IDs means no collision")
    }
}
