import Foundation

/// Shared append/replacement and partial-record handling. Provider parsers own
/// the meaning of records; this operation-local reader owns byte consistency.
public final class CheckpointedJSONLReader {
    public struct Record {
        public let offset: Int64
        public let value: [String: Any]
    }

    public let isIncremental: Bool
    public var snapshot: TranscriptFileSnapshot { reader.snapshot }
    public var bytesRead: Int64 { reader.bytesRead + validationBytes }
    private let path: String
    private let reader: TranscriptFileReader
    private var offset: Int64
    private var validationBytes: Int64
    private let initialContinuity: TranscriptFileContinuity

    public init(path: String, checkpoint: TranscriptSourceCheckpoint?) throws {
        self.path = path
        let current = try TranscriptFileSnapshot.read(at: path)
        var appending = false
        var sampled: Int64 = 0
        if let checkpoint, let continuity = checkpoint.continuity,
           checkpoint.snapshot.hasSameIdentity(as: current), current.size > checkpoint.snapshot.size {
            let actual = try TranscriptFileContinuity.read(at: path, upTo: checkpoint.offset)
            sampled = TranscriptFileContinuity.sampledBytes(upTo: checkpoint.offset)
            appending = actual == continuity
        }
        isIncremental = appending
        reader = try TranscriptFileReader(path: path, fromOffset: appending ? checkpoint!.offset : 0,
                                          includeFinalLine: true)
        guard reader.snapshot == current else { throw TranscriptFileReader.ReadError.changedDuringRead }
        offset = reader.nextOffset
        initialContinuity = try TranscriptFileContinuity.read(at: path, upTo: reader.snapshot.size)
        validationBytes = sampled + TranscriptFileContinuity.sampledBytes(upTo: reader.snapshot.size)
    }

    /// Malformed complete records retain the legacy skip behavior; incomplete
    /// JSON at EOF is retried on the next append. Complete JSON without a final
    /// newline is accepted, including a newline appended in a later batch.
    public func readNext() throws -> Record? {
        while let data = try reader.readNext() {
            let start = offset
            // `JSONSerialization` hands back an autoreleased object tree. Without
            // a pool per record the whole file's trees stay alive until the
            // parse returns; on a large rollout that is most of the footprint.
            var decoded: [String: Any]?
            autoreleasepool {
                decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard let value = decoded else {
                if !reader.lastRecordWasTerminated { return nil }
                offset = reader.nextOffset
                continue
            }
            offset = reader.nextOffset
            return Record(offset: start, value: value)
        }
        return nil
    }

    public func finish() throws -> TranscriptSourceCheckpoint {
        let continuity: TranscriptFileContinuity
        if offset == snapshot.size { continuity = initialContinuity }
        else {
            continuity = try TranscriptFileContinuity.read(at: path, upTo: offset)
            validationBytes += TranscriptFileContinuity.sampledBytes(upTo: offset)
        }
        validationBytes += try reader.validateAppendSnapshot(continuity: initialContinuity)
        return .init(snapshot: snapshot, offset: offset, continuity: continuity)
    }
}
