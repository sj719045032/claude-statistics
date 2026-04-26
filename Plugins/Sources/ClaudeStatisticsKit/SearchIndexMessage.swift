import Foundation

/// One row plugin transcript parsers emit per indexable message. The
/// host's SQLite + FTS5 layer ingests these, but plugins are free to
/// emit whatever role/content/timestamp tuples they consider
/// searchable; the host doesn't second-guess.
public struct SearchIndexMessage: Sendable {
    public let role: String
    public let content: String
    public let timestamp: Date?

    public init(role: String, content: String, timestamp: Date?) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
