import Foundation
import ClaudeStatisticsKit

/// What a session's archive has durably committed: which generation of rows is
/// visible, and how much of which source file they hold.
struct TranscriptArchiveState: Codable, Sendable {
    /// Rows of any other generation belong to an interrupted or superseded pass.
    let generation: Int64
    /// Source identity, archived byte count (`offset`) and bounded continuity
    /// samples of that prefix — the same append-only proof parser checkpoints use.
    let source: TranscriptSourceCheckpoint
}

/// Storage for one session's segmented archive. Visible rows are the committed
/// generation below the committed offset; everything else is uncommitted.
protocol TranscriptArchiveStore {
    func loadArchiveState() -> TranscriptArchiveState?
    /// Drop rows a reader cannot see: other generations, and rows at or past
    /// the committed offset that an interrupted pass left behind.
    func discardUncommittedSegments(committed: TranscriptArchiveState?) -> Bool
    func insertSegment(generation: Int64, sourceOffset: Int64, rawLength: Int64, compressed: Data) -> Bool
    /// Make `state` visible and drop everything it supersedes, atomically.
    func commitArchive(_ state: TranscriptArchiveState) -> Bool
}

/// Archives a transcript as independently compressed fixed-size segments.
///
/// The previous archive read the whole file, compressed it into one blob and
/// bound that blob with a copy — 1.40 GB peak and 18 s of CPU for an 869 MB
/// rollout — and repeated all of it on every hourly pass for a session that had
/// changed at all. Here a pass holds one raw segment and its compressed form,
/// an unchanged source reads nothing, and an appended source compresses only
/// the appended bytes. Segments use the same raw-DEFLATE the old blob used.
enum TranscriptArchiver {
    /// Raw bytes per segment, and therefore the unit of memory for a pass.
    /// DEFLATE's 32 KiB window makes the ratio all but identical to one blob.
    static let segmentSize = 4 * 1024 * 1024
    /// Admission estimate for the shared scheduler: one raw segment, its
    /// compressed form and SQLite's bound copy of it.
    static let estimatedPeakBytes = Int64(segmentSize) * 3

    enum Outcome: Equatable, Sendable {
        case unchanged
        case appended(bytesRead: Int64)
        case rewritten(bytesRead: Int64)
    }

    enum ArchiveError: Error { case sourceChanged, storageFailed }

    static func archive(path: String, into store: some TranscriptArchiveStore,
                        segmentSize: Int = segmentSize) throws -> Outcome {
        precondition(segmentSize > 0)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let snapshot = try TranscriptFileSnapshot.read(descriptor: handle.fileDescriptor)
        // Archive only the file actually open: the path could have been
        // swapped between opening it and reading its metadata.
        guard try TranscriptFileSnapshot.read(at: path) == snapshot else { throw ArchiveError.sourceChanged }

        let committed = store.loadArchiveState()
        if let committed, committed.source.snapshot == snapshot, committed.source.offset == snapshot.size {
            return .unchanged
        }

        // Extend the committed generation only when its prefix is provably
        // still the file's prefix; a replaced, truncated or rewritten source
        // gets a new generation that stays invisible until it is complete.
        var start: Int64 = 0
        var generation = (committed?.generation ?? 0) + 1
        if let committed, snapshot.size > committed.source.offset,
           (try? committed.source.validateAppendOnlySource(at: path)) != nil {
            start = committed.source.offset
            generation = committed.generation
        }
        guard store.discardUncommittedSegments(committed: committed) else { throw ArchiveError.storageFailed }

        let end = snapshot.size
        // Sampled before reading, re-checked before commit.
        let continuity = try TranscriptFileContinuity.read(at: path, upTo: end)
        try handle.seek(toOffset: UInt64(start))
        var position = start
        while position < end {
            try Task.checkCancellation()
            let count = Int(min(Int64(segmentSize), end - position))
            var compressed: Data?
            var read = 0
            // `FileHandle.read` and `NSData.compressed` both autorelease; the
            // compressed copy escapes the pool, the raw segment does not.
            try autoreleasepool {
                guard let raw = try handle.read(upToCount: count) else { return }
                read = raw.count
                compressed = try (raw as NSData).compressed(using: .zlib) as Data
            }
            guard read == count, let compressed else { throw ArchiveError.sourceChanged }
            guard store.insertSegment(generation: generation, sourceOffset: position,
                                      rawLength: Int64(count), compressed: compressed) else {
                throw ArchiveError.storageFailed
            }
            position += Int64(count)
        }

        let state = TranscriptArchiveState(
            generation: generation,
            source: TranscriptSourceCheckpoint(snapshot: snapshot, offset: end, continuity: continuity)
        )
        // What was read must still be the file's prefix: unchanged, or only
        // appended to. Like parser checkpoints this samples the boundaries; it
        // does not prove the absence of an edit in the middle of the history.
        do { try state.source.validateAppendOnlySource(at: path) } catch { throw ArchiveError.sourceChanged }
        guard store.commitArchive(state) else { throw ArchiveError.storageFailed }
        return start > 0 ? .appended(bytesRead: end - start) : .rewritten(bytesRead: end - start)
    }
}
