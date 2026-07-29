import ClaudeStatisticsKit
import XCTest

@testable import Claude_Statistics

@MainActor
final class NotchNotificationCenterTests: XCTestCase {
    func test_enqueueDropsTaskDoneWhenSessionFilterRejects() {
        let tracker = ActiveSessionsTracker()
        tracker.sessionFilters = [RejectingSessionFilter()]
        let center = NotchNotificationCenter()
        center.activeSessionsTracker = tracker

        center.enqueue(makeTaskDoneEvent())

        XCTAssertNil(center.currentEvent)
        XCTAssertEqual(center.queuedCount, 0)
    }

    private func makeTaskDoneEvent() -> AttentionEvent {
        AttentionEvent(
            id: UUID(),
            provider: .codex,
            rawEventName: "Stop",
            notificationType: nil,
            toolName: nil,
            toolInput: nil,
            toolUseId: nil,
            toolResponse: nil,
            message: #"{"suggestions":[]}"#,
            sessionId: "synthetic-\(UUID().uuidString)",
            projectPath: "/tmp/project",
            transcriptPath: nil,
            tty: nil,
            pid: nil,
            terminalName: "codex",
            terminalSocket: nil,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            promptText: nil,
            commentaryText: #"{"suggestions":[]}"#,
            commentaryAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .taskDone(summary: #"{"suggestions":[]}"#),
            pending: nil,
            prepared: nil
        )
    }
}

private struct RejectingSessionFilter: SessionEventFilter {
    let id = "test.reject"

    func shouldDisplay(_ context: SessionFilterContext) -> Bool {
        false
    }
}
