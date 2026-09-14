import Foundation

/// Optional capability, separate from the original protocol so existing binary
/// plugins keep their full-parse compatibility path. Providers own format and
/// deduplication semantics; the host owns atomic persistence and scheduling.
public protocol CheckpointedSessionDataProvider: SessionDataProvider {
    var checkpointParserRevision: String { get }

    /// Return nil only when all source files are unchanged. The checkpoint is
    /// immutable input; return a new checkpoint only for bytes actually consumed.
    /// Throw on IO/format races instead of returning a partial successful result.
    func parseSessionUpdate(at path: String, checkpoint: SessionParseCheckpoint?) throws -> CheckpointedSessionUpdate?
}

public struct TranscriptSourceCheckpoint: Codable, Sendable {
    public let snapshot: TranscriptFileSnapshot
    public let offset: Int64
    public let continuity: TranscriptFileContinuity?

    public init(snapshot: TranscriptFileSnapshot, offset: Int64, continuity: TranscriptFileContinuity? = nil) {
        self.snapshot = snapshot
        self.offset = offset
        self.continuity = continuity
    }

    /// Validate a consumed prefix of an append-only log. Appends after the
    /// captured EOF belong to the next checkpoint, not a reason to discard a
    /// successful long parse. Same-size rewrites/replacements still fail.
    /// Like continuity sampling itself, this is not an arbitrary-mutation
    /// detector; replaceable JSON documents must use strict snapshot validation.
    @discardableResult
    public func validateAppendOnlySource(at path: String) throws -> Int64 {
        let current = try TranscriptFileSnapshot.read(at: path)
        if current == snapshot { return 0 }
        guard snapshot.hasSameIdentity(as: current), current.size > snapshot.size,
              let continuity,
              try TranscriptFileContinuity.read(at: path, upTo: offset) == continuity else {
            throw TranscriptFileReader.ReadError.changedDuringRead
        }
        return TranscriptFileContinuity.sampledBytes(upTo: offset)
    }
}

public struct SessionParseCheckpoint: Codable, Sendable {
    /// Commit identity used to reject updates computed from an obsolete snapshot.
    public let id: UUID
    public let parserRevision: String
    public let sources: [String: TranscriptSourceCheckpoint]
    /// Provider-owned compact parsing state, never the raw transcript.
    public let state: Data

    public init(parserRevision: String, sources: [String: TranscriptSourceCheckpoint], state: Data,
                id: UUID = UUID()) {
        self.id = id
        self.parserRevision = parserRevision
        self.sources = sources
        self.state = state
    }
}

public struct IdentifiedSearchIndexMessage: Sendable {
    /// Stable within a session, e.g. source identity + record offset + text part,
    /// or a provider's mutable message ID. Replaying this ID replaces its row.
    public let id: String
    public let message: SearchIndexMessage

    public init(id: String, message: SearchIndexMessage) {
        self.id = id
        self.message = message
    }
}

public enum SessionSearchIndexUpdate: Sendable {
    case preserve
    case replace([SearchIndexMessage])
    case replaceIdentified([IdentifiedSearchIndexMessage])
    case update(upserting: [IdentifiedSearchIndexMessage], removing: [String])
}

public struct CheckpointedSessionUpdate: Sendable {
    public let stats: SessionStats
    public let quickStats: SessionQuickStats
    public let searchIndex: SessionSearchIndexUpdate
    public let checkpoint: SessionParseCheckpoint
    public let bytesRead: Int64

    public init(stats: SessionStats, quickStats: SessionQuickStats,
                searchIndex: SessionSearchIndexUpdate, checkpoint: SessionParseCheckpoint,
                bytesRead: Int64) {
        self.stats = stats
        self.quickStats = quickStats
        self.searchIndex = searchIndex
        self.checkpoint = checkpoint
        self.bytesRead = bytesRead
    }
}
