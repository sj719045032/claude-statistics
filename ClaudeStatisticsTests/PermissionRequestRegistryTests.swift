import XCTest

@testable import Claude_Statistics

final class PermissionRequestRegistryTests: XCTestCase {
    private func makeEvent(
        provider: ProviderKind = .claude,
        sessionId: String = "s1",
        kind: AttentionKind,
        rawEventName: String,
        toolName: String? = nil,
        toolUseId: String? = nil
    ) -> AttentionEvent {
        AttentionEvent(
            id: UUID(),
            provider: provider,
            rawEventName: rawEventName,
            notificationType: nil,
            toolName: toolName,
            toolInput: nil,
            toolUseId: toolUseId,
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
            kind: kind,
            pending: nil
        )
    }

    private func permissionEvent(tool: String, toolUseId: String) -> AttentionEvent {
        makeEvent(
            kind: .permissionRequest(tool: tool, input: [:], toolUseId: toolUseId, interaction: .actionable),
            rawEventName: "PermissionRequest",
            toolName: tool,
            toolUseId: toolUseId
        )
    }

    // MARK: - register / unregister

    func test_register_firstReturnsNilAndStores() {
        var registry = PermissionRequestRegistry()
        let id = UUID()
        XCTAssertNil(registry.register(toolUseId: "t1", eventId: id))
    }

    func test_register_duplicateReturnsExistingId() {
        var registry = PermissionRequestRegistry()
        let firstId = UUID()
        let secondId = UUID()
        _ = registry.register(toolUseId: "t1", eventId: firstId)
        XCTAssertEqual(registry.register(toolUseId: "t1", eventId: secondId), firstId)
    }

    func test_register_emptyToolUseIdNoOp() {
        var registry = PermissionRequestRegistry()
        XCTAssertNil(registry.register(toolUseId: "", eventId: UUID()))
        // Empty also doesn't create a slot to dedup against.
        XCTAssertNil(registry.register(toolUseId: "", eventId: UUID()))
    }

    func test_unregisterAllowsReregistration() {
        var registry = PermissionRequestRegistry()
        let firstId = UUID()
        let secondId = UUID()
        _ = registry.register(toolUseId: "t1", eventId: firstId)
        registry.unregister(toolUseId: "t1")
        XCTAssertNil(registry.register(toolUseId: "t1", eventId: secondId))
    }

    func test_unregister_unknownIsNoOp() {
        var registry = PermissionRequestRegistry()
        registry.unregister(toolUseId: "never-existed")  // no crash
    }

    func test_unregister_emptyToolUseIdNoOp() {
        var registry = PermissionRequestRegistry()
        registry.unregister(toolUseId: "")  // no crash
    }

    // MARK: - shouldClearPermission: kind/scope guards

    func test_shouldClear_falseWhenCandidateNotPermission() {
        let candidate = makeEvent(kind: .activityPulse, rawEventName: "X")
        let trigger = makeEvent(kind: .activityPulse, rawEventName: "Stop")
        XCTAssertFalse(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_falseWhenDifferentProvider() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(provider: .codex, kind: .activityPulse, rawEventName: "Stop")
        XCTAssertFalse(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_falseWhenDifferentSession() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(sessionId: "s-other", kind: .activityPulse, rawEventName: "Stop")
        XCTAssertFalse(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    // MARK: - shouldClearPermission: terminal triggers

    func test_shouldClear_stopUnconditionallyClears() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(kind: .activityPulse, rawEventName: "Stop")
        XCTAssertTrue(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_stopFailureUnconditionallyClears() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(kind: .activityPulse, rawEventName: "StopFailure")
        XCTAssertTrue(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_sessionEndUnconditionallyClears() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(kind: .sessionEnd, rawEventName: "SessionEnd")
        XCTAssertTrue(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    // MARK: - shouldClearPermission: toolUseId match

    func test_shouldClear_matchingToolUseIdClears() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(
            kind: .activityPulse,
            rawEventName: "PostToolUse",
            toolName: "Bash",
            toolUseId: "t1"
        )
        XCTAssertTrue(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_mismatchedToolUseIdDoesNotClear() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(
            kind: .activityPulse,
            rawEventName: "PostToolUse",
            toolName: "Bash",
            toolUseId: "t2"
        )
        XCTAssertFalse(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_triggerToolUseIdWhitespaceTrimmed() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "t1")
        let trigger = makeEvent(
            kind: .activityPulse,
            rawEventName: "PostToolUse",
            toolName: "Bash",
            toolUseId: "  t1  "
        )
        XCTAssertTrue(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    // MARK: - shouldClearPermission: tool-name fallback

    func test_shouldClear_fallsBackToToolNameWhenNoToolUseId() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "")
        let trigger = makeEvent(
            kind: .activityPulse,
            rawEventName: "PostToolUse",
            toolName: "BASH",
            toolUseId: nil
        )
        XCTAssertTrue(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_toolNameMismatchKeepsCandidate() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "")
        let trigger = makeEvent(
            kind: .activityPulse,
            rawEventName: "PostToolUse",
            toolName: "Read",
            toolUseId: nil
        )
        XCTAssertFalse(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }

    func test_shouldClear_noToolNameFallbackKeepsCandidate() {
        let candidate = permissionEvent(tool: "Bash", toolUseId: "")
        let trigger = makeEvent(kind: .activityPulse, rawEventName: "PostToolUse")
        XCTAssertFalse(PermissionRequestRegistry.shouldClearPermission(candidate: candidate, becauseOf: trigger))
    }
}
