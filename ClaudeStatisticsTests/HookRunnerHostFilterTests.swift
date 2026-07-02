import XCTest

@testable import Claude_Statistics

final class HookRunnerHostFilterTests: XCTestCase {
    func test_shouldDropUnclaimedHostBeforeSocket_keepsPermissionRequest() {
        XCTAssertFalse(
            HookRunner.shouldDropUnclaimedHostBeforeSocket(
                payload: ["hook_event_name": "PermissionRequest"],
                hostAppBundleId: "com.openai.codex",
                installedTerminalBundles: ["com.apple.Terminal"],
                marketplaceHasTerminalPlugin: { _ in false }
            )
        )
    }

    func test_shouldDropUnclaimedHostBeforeSocket_keepsToolPermission() {
        XCTAssertFalse(
            HookRunner.shouldDropUnclaimedHostBeforeSocket(
                payload: ["hook_event_name": "ToolPermission"],
                hostAppBundleId: "com.openai.codex",
                installedTerminalBundles: ["com.apple.Terminal"],
                marketplaceHasTerminalPlugin: { _ in false }
            )
        )
    }

    func test_shouldDropUnclaimedHostBeforeSocket_keepsPermissionNotification() {
        XCTAssertFalse(
            HookRunner.shouldDropUnclaimedHostBeforeSocket(
                payload: [
                    "hook_event_name": "Notification",
                    "notification_type": "permission_prompt",
                ],
                hostAppBundleId: "com.openai.codex",
                installedTerminalBundles: ["com.apple.Terminal"],
                marketplaceHasTerminalPlugin: { _ in false }
            )
        )
    }

    func test_shouldDropUnclaimedHostBeforeSocket_dropsNonPermissionUnclaimedHost() {
        XCTAssertTrue(
            HookRunner.shouldDropUnclaimedHostBeforeSocket(
                payload: ["hook_event_name": "Stop"],
                hostAppBundleId: "com.openai.codex",
                installedTerminalBundles: ["com.apple.Terminal"],
                marketplaceHasTerminalPlugin: { _ in false }
            )
        )
    }

    func test_shouldDropUnclaimedHostBeforeSocket_keepsMarketplaceTerminalHost() {
        XCTAssertFalse(
            HookRunner.shouldDropUnclaimedHostBeforeSocket(
                payload: ["hook_event_name": "Stop"],
                hostAppBundleId: "com.openai.codex",
                installedTerminalBundles: ["com.apple.Terminal"],
                marketplaceHasTerminalPlugin: { _ in true }
            )
        )
    }
}
