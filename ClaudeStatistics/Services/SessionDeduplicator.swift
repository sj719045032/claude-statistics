import Foundation
import ClaudeStatisticsKit

/// Drops duplicate `Session` entries that share the same id, keeping the one
/// most likely to be the real source of truth (latest mtime, then largest
/// file, then lexicographically last path as a tiebreaker).
///
/// Pure / stateless — provider scanners can produce duplicates when the user
/// has the same session symlinked or copied across project directories, and
/// downstream code assumes ids are unique.
enum SessionDeduplicator {
    static func deduplicate(_ sessions: [Session], provider: ProviderKind) -> [Session] {
        guard !sessions.isEmpty else { return [] }

        var bestById: [String: Session] = [:]
        var duplicateCounts: [String: Int] = [:]

        for session in sessions {
            if let existing = bestById[session.id] {
                duplicateCounts[session.id, default: 1] += 1
                if shouldReplace(existing: existing, with: session) {
                    bestById[session.id] = session
                }
            } else {
                bestById[session.id] = session
            }
        }

        if !duplicateCounts.isEmpty {
            let sample = duplicateCounts
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }
                .prefix(5)
                .map { "\($0.key)(x\($0.value))" }
                .joined(separator: ", ")
            DiagnosticLogger.shared.warning(
                "Deduplicated \(provider.rawValue) sessions by id: dropped \(sessions.count - bestById.count) duplicates; sample: \(sample)"
            )
        }

        return bestById.values.sorted { $0.lastModified > $1.lastModified }
    }

    private static func shouldReplace(existing: Session, with candidate: Session) -> Bool {
        if candidate.lastModified != existing.lastModified {
            return candidate.lastModified > existing.lastModified
        }
        if candidate.fileSize != existing.fileSize {
            return candidate.fileSize > existing.fileSize
        }
        return candidate.filePath > existing.filePath
    }
}
