import Foundation
import ClaudeStatisticsKit

/// Provider-neutral metadata contract used by plugins that expose child
/// sessions. Keep the string values aligned with provider implementations;
/// storing them in `Session.metadata` avoids an SDK ABI/version dependency.
enum SessionRelationshipMetadataKey {
    static let parentSessionID = "session.relationship.parentID"
    static let agentDepth = "session.relationship.agentDepth"
    static let agentPath = "session.relationship.agentPath"
    static let agentNickname = "session.relationship.agentNickname"
}

extension Session {
    var isSubagentSession: Bool {
        parentSessionID != nil
    }

    var parentSessionID: String? {
        nonEmptyRelationshipValue(for: SessionRelationshipMetadataKey.parentSessionID)
    }

    var agentDepth: Int? {
        guard let raw = nonEmptyRelationshipValue(for: SessionRelationshipMetadataKey.agentDepth) else {
            return nil
        }
        return Int(raw)
    }

    var agentPath: String? {
        nonEmptyRelationshipValue(for: SessionRelationshipMetadataKey.agentPath)
    }

    var agentNickname: String? {
        nonEmptyRelationshipValue(for: SessionRelationshipMetadataKey.agentNickname)
    }

    var agentDisplayName: String? {
        if let agentPath {
            let component = (agentPath as NSString).lastPathComponent
            if !component.isEmpty { return component }
        }
        return agentNickname
    }

    private func nonEmptyRelationshipValue(for key: String) -> String? {
        guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct SessionFamily: Identifiable {
    let root: Session
    let descendants: [Session]

    var id: String { root.id }
    var allSessions: [Session] { [root] + descendants }
    var sessionIDs: Set<String> { Set(allSessions.map(\.id)) }
    var latestModified: Date {
        descendants.reduce(root.lastModified) { max($0, $1.lastModified) }
    }
}

struct SessionListMetrics {
    let messageCount: Int
    let totalTokens: Int
    let estimatedCost: Double

    static func aggregate(
        sessions: [Session],
        parsedStats: [String: SessionStats],
        quickStats: [String: SessionQuickStats]
    ) -> SessionListMetrics? {
        var foundMetrics = false
        var messages = 0
        var tokens = 0
        var cost = 0.0

        for session in sessions {
            if let stats = parsedStats[session.id] {
                foundMetrics = true
                messages += stats.messageCount
                tokens += stats.totalTokens
                cost += stats.estimatedCost
            } else if let quick = quickStats[session.id] {
                foundMetrics = true
                messages += quick.messageCount
                tokens += quick.totalTokens
                cost += quick.estimatedCost
            }
        }

        guard foundMetrics else { return nil }
        return SessionListMetrics(
            messageCount: messages,
            totalTokens: tokens,
            estimatedCost: cost
        )
    }
}

enum SessionHierarchy {
    static func families(from sessions: [Session]) -> [SessionFamily] {
        guard !sessions.isEmpty else { return [] }

        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: sessions) { session in
            rootID(for: session, sessionsByID: byID)
        }

        return grouped.compactMap { rootID, members in
            guard let root = byID[rootID] else { return nil }
            let descendants = members
                .filter { $0.id != rootID }
                .sorted(by: descendantSort)
            return SessionFamily(root: root, descendants: descendants)
        }
        .sorted {
            if $0.latestModified == $1.latestModified { return $0.id > $1.id }
            return $0.latestModified > $1.latestModified
        }
    }

    static func includingAncestors(of sessions: [Session], from allSessions: [Session]) -> [Session] {
        guard !sessions.isEmpty else { return [] }

        let allByID = Dictionary(allSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for session in sessions {
            var current = session
            var visited = Set([session.id])
            while let parentID = current.parentSessionID,
                  !visited.contains(parentID),
                  let parent = allByID[parentID] {
                included[parentID] = parent
                visited.insert(parentID)
                current = parent
            }
        }

        return included.values.sorted { $0.lastModified > $1.lastModified }
    }

    private static func rootID(for session: Session, sessionsByID: [String: Session]) -> String {
        var current = session
        var visited = Set([session.id])

        while let parentID = current.parentSessionID,
              let parent = sessionsByID[parentID] {
            if visited.contains(parentID) {
                return visited.min() ?? session.id
            }
            visited.insert(parentID)
            current = parent
        }

        return current.id
    }

    private static func descendantSort(_ lhs: Session, _ rhs: Session) -> Bool {
        let lhsDepth = lhs.agentDepth ?? Int.max
        let rhsDepth = rhs.agentDepth ?? Int.max
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        if lhs.lastModified != rhs.lastModified { return lhs.lastModified > rhs.lastModified }
        return lhs.id < rhs.id
    }
}
