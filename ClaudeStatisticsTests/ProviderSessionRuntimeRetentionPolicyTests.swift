import Foundation
import XCTest

@testable import Claude_Statistics

final class ProviderSessionRuntimeRetentionPolicyTests: XCTestCase {
    private func makeRuntime(
        lastActivityAt: Date,
        status: ActiveSessionStatus = .idle,
        pid: Int32? = nil,
        currentOperation: CurrentOperation? = nil,
        currentToolStartedAt: Date? = nil,
        approvalStartedAt: Date? = nil,
        activeTools: [String: ActiveToolEntry] = [:],
        recentlyCompletedTools: [CompletedToolEntry]? = nil
    ) -> RuntimeSession {
        var json: [String: Any] = [
            "provider": ProviderKind.codex.rawValue,
            "sessionId": "codex-session",
            "lastActivityAt": lastActivityAt.timeIntervalSinceReferenceDate,
            "status": status.rawValue,
            "backgroundShellCount": 0,
            "activeSubagentCount": 0,
            "activeTools": [String: Any]()
        ]
        if let pid { json["pid"] = Int(pid) }
        if let currentOperation {
            var operation: [String: Any] = [
                "kind": currentOperation.kind.rawValue,
                "text": currentOperation.text,
                "symbol": currentOperation.symbol,
                "startedAt": currentOperation.startedAt.timeIntervalSinceReferenceDate
            ]
            if let toolName = currentOperation.toolName { operation["toolName"] = toolName }
            if let toolUseId = currentOperation.toolUseId { operation["toolUseId"] = toolUseId }
            json["currentOperation"] = operation
        }
        if let currentToolStartedAt {
            json["currentToolStartedAt"] = currentToolStartedAt.timeIntervalSinceReferenceDate
        }
        if let approvalStartedAt {
            json["approvalStartedAt"] = approvalStartedAt.timeIntervalSinceReferenceDate
        }
        if !activeTools.isEmpty {
            json["activeTools"] = activeTools.mapValues { entry in
                var tool: [String: Any] = [
                    "toolName": entry.toolName,
                    "startedAt": entry.startedAt.timeIntervalSinceReferenceDate
                ]
                if let detail = entry.detail { tool["detail"] = detail }
                return tool
            }
        }
        if let recentlyCompletedTools {
            json["recentlyCompletedTools"] = recentlyCompletedTools.map { entry in
                var tool: [String: Any] = [
                    "toolName": entry.toolName,
                    "startedAt": entry.startedAt.timeIntervalSinceReferenceDate,
                    "completedAt": entry.completedAt.timeIntervalSinceReferenceDate,
                    "failed": entry.failed
                ]
                if let detail = entry.detail { tool["detail"] = detail }
                return tool
            }
        }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(RuntimeSession.self, from: data)
    }

    func test_recentActivityKeepsSessionWithoutPid() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let runtime = makeRuntime(lastActivityAt: now.addingTimeInterval(-30))

        XCTAssertTrue(
            ProviderSessionRuntimeRetentionPolicy.shouldKeep(runtime: runtime, cutoff: cutoff, now: now)
        )
    }

    func test_staleIdleDropsEvenWhenHostPidIsAlive() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let runtime = makeRuntime(
            lastActivityAt: now.addingTimeInterval(-600),
            pid: getpid()
        )

        XCTAssertFalse(
            ProviderSessionRuntimeRetentionPolicy.shouldKeep(runtime: runtime, cutoff: cutoff, now: now),
            "provider sessions should not stay visible just because the host app process is alive"
        )
    }

    func test_staleRunningWithoutFreshEvidenceDrops() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let runtime = makeRuntime(
            lastActivityAt: now.addingTimeInterval(-600),
            status: .running,
            pid: getpid()
        )

        XCTAssertFalse(
            ProviderSessionRuntimeRetentionPolicy.shouldKeep(runtime: runtime, cutoff: cutoff, now: now)
        )
    }

    func test_staleRunningWithFreshOperationKeeps() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let runtime = makeRuntime(
            lastActivityAt: now.addingTimeInterval(-600),
            currentOperation: CurrentOperation(
                kind: .tool,
                text: "Reading files",
                symbol: "doc.text",
                startedAt: now.addingTimeInterval(-60),
                toolName: "Read",
                toolUseId: "tool-1"
            )
        )

        XCTAssertTrue(
            ProviderSessionRuntimeRetentionPolicy.shouldKeep(runtime: runtime, cutoff: cutoff, now: now)
        )
    }

    func test_staleRunningWithOldOperationDrops() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let runtime = makeRuntime(
            lastActivityAt: now.addingTimeInterval(-600),
            currentOperation: CurrentOperation(
                kind: .tool,
                text: "Reading files",
                symbol: "doc.text",
                startedAt: now.addingTimeInterval(-600),
                toolName: "Read",
                toolUseId: "tool-1"
            )
        )

        XCTAssertFalse(
            ProviderSessionRuntimeRetentionPolicy.shouldKeep(runtime: runtime, cutoff: cutoff, now: now)
        )
    }

    func test_staleSessionWithFreshActiveToolKeeps() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let runtime = makeRuntime(
            lastActivityAt: now.addingTimeInterval(-600),
            activeTools: [
                "tool-1": ActiveToolEntry(toolName: "Read", detail: nil, startedAt: now.addingTimeInterval(-60))
            ]
        )

        XCTAssertTrue(
            ProviderSessionRuntimeRetentionPolicy.shouldKeep(runtime: runtime, cutoff: cutoff, now: now)
        )
    }

    func test_staleWaitingDropsAfterActiveWindow() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-300)
        let runtime = makeRuntime(
            lastActivityAt: now.addingTimeInterval(-600),
            status: .waiting,
            pid: getpid()
        )

        XCTAssertFalse(
            ProviderSessionRuntimeRetentionPolicy.shouldKeep(runtime: runtime, cutoff: cutoff, now: now)
        )
    }
}
