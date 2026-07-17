import Foundation
import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

final class SessionHierarchyTests: XCTestCase {
    func testFamiliesFoldNestedAgentsIntoRoot() throws {
        let root = makeSession(id: "root", modified: 10)
        let child = makeSession(id: "child", modified: 30, parentID: "root", depth: 1, path: "/root/review")
        let grandchild = makeSession(id: "grandchild", modified: 20, parentID: "child", depth: 2, path: "/root/review/tests")
        let standalone = makeSession(id: "standalone", modified: 15)

        let families = SessionHierarchy.families(from: [root, child, grandchild, standalone])

        XCTAssertEqual(families.map(\.root.id), ["root", "standalone"])
        let rootFamily = try XCTUnwrap(families.first)
        XCTAssertEqual(rootFamily.descendants.map(\.id), ["child", "grandchild"])
        XCTAssertEqual(rootFamily.sessionIDs, ["root", "child", "grandchild"])
        XCTAssertEqual(rootFamily.latestModified, child.lastModified)
        XCTAssertEqual(child.agentDisplayName, "review")
        XCTAssertFalse(root.isSubagentSession)
        XCTAssertTrue(child.isSubagentSession)
    }

    func testOrphanAgentRemainsVisibleAsItsOwnFamily() throws {
        let orphan = makeSession(id: "orphan", modified: 10, parentID: "missing", depth: 1)

        let family = try XCTUnwrap(SessionHierarchy.families(from: [orphan]).first)

        XCTAssertEqual(family.root.id, "orphan")
        XCTAssertTrue(family.descendants.isEmpty)
    }

    func testSearchResultsIncludeAvailableAncestors() {
        let root = makeSession(id: "root", modified: 10)
        let child = makeSession(id: "child", modified: 20, parentID: "root", depth: 1)
        let grandchild = makeSession(id: "grandchild", modified: 30, parentID: "child", depth: 2)

        let included = SessionHierarchy.includingAncestors(
            of: [grandchild],
            from: [root, child, grandchild]
        )

        XCTAssertEqual(Set(included.map(\.id)), ["root", "child", "grandchild"])
    }

    func testAggregateMetricsUseFullStatsOrQuickStatsOncePerSession() throws {
        let root = makeSession(id: "root", modified: 10)
        let child = makeSession(id: "child", modified: 20, parentID: "root", depth: 1)
        let quickStats = [
            root.id: SessionQuickStats(messageCount: 4, totalTokens: 1_000, estimatedCost: 1.25),
            child.id: SessionQuickStats(messageCount: 6, totalTokens: 2_000, estimatedCost: 2.75),
        ]

        let metrics = try XCTUnwrap(SessionListMetrics.aggregate(
            sessions: [root, child],
            parsedStats: [:],
            quickStats: quickStats
        ))

        XCTAssertEqual(metrics.messageCount, 10)
        XCTAssertEqual(metrics.totalTokens, 3_000)
        XCTAssertEqual(metrics.estimatedCost, 4.0, accuracy: 0.0001)
    }

    private func makeSession(
        id: String,
        modified: TimeInterval,
        parentID: String? = nil,
        depth: Int? = nil,
        path: String? = nil
    ) -> Session {
        var metadata: [String: String] = [:]
        if let parentID {
            metadata[SessionRelationshipMetadataKey.parentSessionID] = parentID
        }
        if let depth {
            metadata[SessionRelationshipMetadataKey.agentDepth] = String(depth)
        }
        if let path {
            metadata[SessionRelationshipMetadataKey.agentPath] = path
        }
        return Session(
            id: id,
            externalID: id,
            provider: "test",
            projectPath: "/tmp/project",
            filePath: "/tmp/\(id).jsonl",
            startTime: nil,
            lastModified: Date(timeIntervalSince1970: modified),
            fileSize: 1,
            metadata: metadata
        )
    }
}
