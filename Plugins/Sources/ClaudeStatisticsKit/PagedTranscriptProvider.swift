import Foundation

/// A half-open byte range of one source file.
public struct TranscriptByteRange: Sendable, Hashable, Codable {
    public let offset: Int64
    public let length: Int64

    public init(offset: Int64, length: Int64) {
        precondition(offset >= 0 && length >= 0)
        self.offset = offset
        self.length = length
    }

    public var end: Int64 { offset + length }
}

/// Where one display row's bytes live. The provider fills this in during the
/// outline pass and gets it back verbatim when the host asks for a page, so
/// materializing a window never rescans the history. `ranges` are the records
/// the row needs — a tool row typically cites its call record plus the later
/// record carrying its result.
public struct TranscriptRecordLocator: Sendable, Hashable, Codable {
    /// File holding the records. Child/subagent rows cite their own file.
    public let source: String
    public let ranges: [TranscriptByteRange]

    public init(source: String, ranges: [TranscriptByteRange]) {
        self.source = source
        self.ranges = ranges
    }

    public var byteCount: Int64 { ranges.reduce(0) { $0 + $1.length } }
}

/// Bounded description of one transcript row: enough to lay out, filter and
/// count rows without retaining any message body. Roughly two orders of
/// magnitude smaller than the `TranscriptDisplayMessage` it points at.
public struct TranscriptOutlineEntry: Sendable, Identifiable, Hashable {
    public let id: String
    public let role: String
    public let toolName: String?
    public let timestamp: Date?
    public let locator: TranscriptRecordLocator
    /// Provider-owned context needed to rebuild the row that its bytes alone do
    /// not carry — e.g. a record's position within the session, which a
    /// provider may use to name cached attachments. Opaque to the host.
    public let token: String?

    public init(id: String, role: String, toolName: String? = nil,
                timestamp: Date? = nil, locator: TranscriptRecordLocator, token: String? = nil) {
        self.id = id
        self.role = role
        self.toolName = toolName
        self.timestamp = timestamp
        self.locator = locator
        self.token = token
    }
}

public struct TranscriptOutline: Sendable {
    public let entries: [TranscriptOutlineEntry]
    /// Every source file the outline was built from, and how much of it. The
    /// host rebuilds the outline when one of them stops validating.
    public let sources: [String: TranscriptSourceCheckpoint]

    public init(entries: [TranscriptOutlineEntry], sources: [String: TranscriptSourceCheckpoint]) {
        self.entries = entries
        self.sources = sources
    }

    /// `true` while every cited source is unchanged or only appended to.
    /// Appends leave every recorded byte range valid — an actively written
    /// transcript must not rebuild its outline on each page. A replaced,
    /// truncated or boundary-rewritten source keeps old offsets in range, so a
    /// page read from it would be plausible and wrong: callers check before
    /// committing a page.
    public func matchesSources() -> Bool { Self.sourcesMatch(sources) }

    public static func sourcesMatch(_ sources: [String: TranscriptSourceCheckpoint]) -> Bool {
        sources.allSatisfy { path, source in
            (try? source.validateAppendOnlySource(at: path)) != nil
        }
    }
}

extension TranscriptSourceCheckpoint {
    /// A source fully covered by an outline: offsets up to `snapshot.size`, with
    /// continuity samples of that prefix so later validation tolerates appends.
    public static func coveringWholeFile(_ snapshot: TranscriptFileSnapshot, at path: String) throws -> Self {
        Self(snapshot: snapshot, offset: snapshot.size,
             continuity: try TranscriptFileContinuity.read(at: path, upTo: snapshot.size))
    }
}

/// Optional capability: serve the transcript detail view a bounded window
/// instead of every message. Providers that do not adopt it keep the existing
/// whole-file `parseMessages` path, which the host bounds by concurrency only.
///
/// The host owns windowing, caching and search orchestration; the provider
/// owns record identity and how a row is rebuilt from its bytes.
public protocol PagedTranscriptProvider: SessionDataProvider {
    /// One streaming pass over the session's files emitting an outline row per
    /// display row, in display order. Memory must scale with the row count,
    /// not the transcript size.
    func loadTranscriptOutline(at path: String) throws -> TranscriptOutline

    /// Materialize exactly these rows by reading only their locators' bytes.
    /// Returns rows in the requested order, carrying the requested `id`s.
    /// Rows whose bytes no longer parse are omitted rather than faked.
    func loadTranscriptPage(at path: String, entries: [TranscriptOutlineEntry]) throws -> [TranscriptDisplayMessage]
}

/// Random-access record reader for page materialization. Reads only the cited
/// ranges; retains one record at a time plus the caller's result.
public struct TranscriptRecordReader {
    private let handle: FileHandle
    public let snapshot: TranscriptFileSnapshot

    public init(path: String) throws {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        do {
            snapshot = try TranscriptFileSnapshot.read(at: path)
        } catch {
            try? file.close()
            throw error
        }
        handle = file
    }

    public func close() { try? handle.close() }

    /// Returns nil when the range no longer lies inside the file — a replaced
    /// or truncated source, which the caller reports as a stale page.
    public func read(_ range: TranscriptByteRange) throws -> Data? {
        guard range.end <= snapshot.size else { return nil }
        try handle.seek(toOffset: UInt64(range.offset))
        // `FileHandle.read` is autoreleased. A page load reads dozens of
        // ranges and a full-history search reads every one in the transcript,
        // so the copy has to escape the pool, not the read.
        var data = Data()
        try autoreleasepool {
            if let chunk = try handle.read(upToCount: Int(range.length)) { data.append(chunk) }
        }
        return data.count == Int(range.length) ? data : nil
    }
}
