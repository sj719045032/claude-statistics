import XCTest

@testable import Claude_Statistics

final class AttentionBridgeTests: XCTestCase {
    func test_shouldDropUnclaimedHost_keepsPermissionRequests() {
        let kind = AttentionKind.permissionRequest(
            tool: "Bash",
            input: [:],
            toolUseId: "tool-1",
            interaction: .actionable
        )

        XCTAssertFalse(
            AttentionBridge.shouldDropUnclaimedHost(
                claimed: false,
                hostAppBundleId: "com.openai.codex",
                kind: kind
            )
        )
    }

    func test_shouldDropUnclaimedHost_dropsNonPermissionGuiEvents() {
        XCTAssertTrue(
            AttentionBridge.shouldDropUnclaimedHost(
                claimed: false,
                hostAppBundleId: "com.openai.codex",
                kind: .taskDone(summary: nil)
            )
        )
    }

    func test_shouldDropUnclaimedHost_keepsClaimedGuiEvents() {
        XCTAssertFalse(
            AttentionBridge.shouldDropUnclaimedHost(
                claimed: true,
                hostAppBundleId: "com.openai.codex",
                kind: .taskDone(summary: nil)
            )
        )
    }
}
