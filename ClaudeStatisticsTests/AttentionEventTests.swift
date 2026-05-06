import Foundation
import XCTest

@testable import Claude_Statistics

final class AttentionEventTests: XCTestCase {
    func test_taskDoneLivePreviewFallsBackToCommentaryText() {
        let event = AttentionEvent(
            id: UUID(),
            provider: .claude,
            rawEventName: "Stop",
            notificationType: nil,
            toolName: nil,
            toolInput: nil,
            toolUseId: nil,
            toolResponse: nil,
            message: nil,
            sessionId: "session",
            projectPath: nil,
            transcriptPath: nil,
            tty: nil,
            pid: nil,
            terminalName: nil,
            terminalSocket: nil,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            promptText: nil,
            commentaryText: "\n  Final answer from the transcript.  \n",
            commentaryAt: Date(timeIntervalSince1970: 1_700_000_001),
            kind: .taskDone(summary: nil),
            pending: nil
        )

        XCTAssertEqual(event.livePreview, "Final answer from the transcript.")
    }

    func test_taskDoneLivePreviewPrefersExplicitSummary() {
        let event = AttentionEvent(
            id: UUID(),
            provider: .claude,
            rawEventName: "Stop",
            notificationType: nil,
            toolName: nil,
            toolInput: nil,
            toolUseId: nil,
            toolResponse: nil,
            message: "Explicit completion summary",
            sessionId: "session",
            projectPath: nil,
            transcriptPath: nil,
            tty: nil,
            pid: nil,
            terminalName: nil,
            terminalSocket: nil,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            promptText: nil,
            commentaryText: "Final answer from the transcript.",
            commentaryAt: Date(timeIntervalSince1970: 1_700_000_001),
            kind: .taskDone(summary: "Explicit completion summary"),
            pending: nil
        )

        XCTAssertEqual(event.livePreview, "Explicit completion summary")
    }
}
