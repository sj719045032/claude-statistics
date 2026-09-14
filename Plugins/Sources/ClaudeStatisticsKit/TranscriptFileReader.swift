import Foundation
import Darwin

/// Identity and metadata of the actual file, never the aggregate size of a
/// session family. Nanoseconds are retained for same-size rapid rewrites.
public struct TranscriptFileSnapshot: Codable, Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    private init(_ value: Darwin.stat) {
        device = Int64(value.st_dev)
        inode = UInt64(value.st_ino)
        size = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }

    public var modifiedAt: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }

    public func hasSameIdentity(as other: Self) -> Bool {
        device == other.device && inode == other.inode
    }

    public static func read(at path: String) throws -> Self {
        var value = Darwin.stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &value, 0) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Self(value)
    }

    /// Snapshot of an already-open file. Comparing it with `read(at:)` proves
    /// the descriptor being read is the file currently at that path.
    public static func read(descriptor: Int32) throws -> Self {
        var value = Darwin.stat()
        guard fstat(descriptor, &value) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Self(value)
    }
}

/// Chunked JSONL reader. Memory is bounded by a chunk plus the largest record,
/// not the transcript's history. Each byte is scanned once, even for long lines.
/// A reader is confined to one parse operation; it is not shared across threads.
public final class TranscriptFileReader {
    public enum ReadError: Error { case invalidOffset, truncatedDuringRead, changedDuringRead }

    public let snapshot: TranscriptFileSnapshot
    public private(set) var nextOffset: Int64
    public private(set) var bytesRead: Int64 = 0
    public private(set) var lastRecordWasTerminated = false

    private let handle: FileHandle
    private let path: String
    private let chunkSize: Int
    private let includeFinalLine: Bool
    private var position: Int64
    private var bufferOffset: Int64
    private var buffer = Data()
    private var consumed = 0
    private var searched = 0

    /// Append parsing leaves unterminated records for the next pass. A full
    /// snapshot parser can opt into the historic final-line-without-newline behavior.
    public init(path: String, fromOffset: Int64 = 0, chunkSize: Int = 64 * 1024,
                includeFinalLine: Bool = false) throws {
        precondition(chunkSize > 0)
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        do {
            let state = try TranscriptFileSnapshot.read(descriptor: file.fileDescriptor)
            guard fromOffset >= 0, fromOffset <= state.size else { throw ReadError.invalidOffset }
            try file.seek(toOffset: UInt64(fromOffset))
            snapshot = state
        } catch {
            try? file.close()
            throw error
        }
        handle = file
        self.path = path
        self.chunkSize = chunkSize
        self.includeFinalLine = includeFinalLine
        position = fromOffset
        bufferOffset = fromOffset
        nextOffset = fromOffset
    }

    deinit { try? handle.close() }

    public func readNext() throws -> Data? {
        while true {
            try Task.checkCancellation()
            // `Data.firstIndex(of:)` is not specialized across the module
            // boundary: it walks byte by byte through protocol witnesses and was
            // the hottest frame when sampling a transcript scan. `memchr` is a
            // vectorized search over the same bytes.
            let newline: Int? = buffer.withUnsafeBytes { raw in
                guard searched < raw.count, let base = raw.baseAddress,
                      let hit = memchr(base + searched, 0x0A, raw.count - searched) else { return nil }
                return base.distance(to: UnsafeRawPointer(hit))
            }
            if let newline {
                let start = buffer.index(buffer.startIndex, offsetBy: consumed)
                let record = buffer.subdata(in: start..<buffer.index(buffer.startIndex, offsetBy: newline))
                consumed = newline + 1
                searched = consumed
                nextOffset = bufferOffset + Int64(consumed)
                lastRecordWasTerminated = true
                return record
            }
            searched = buffer.count
            if position == snapshot.size {
                guard includeFinalLine, consumed < buffer.count else { return nil }
                let record = Data(buffer.dropFirst(consumed))
                consumed = buffer.count
                searched = consumed
                nextOffset = position
                lastRecordWasTerminated = false
                return record
            }
            if consumed > 0 {
                buffer = Data(buffer.dropFirst(consumed))
                bufferOffset += Int64(consumed)
                searched -= consumed
                consumed = 0
            }
            let count = Int(min(Int64(chunkSize), snapshot.size - position))
            // `FileHandle.read` hands back an autoreleased `NSData`. Copy it
            // into the buffer inside a pool: without one, every chunk of the
            // file stays alive in the caller's pool until the whole parse
            // returns, which defeats the point of reading in chunks at all.
            var appended = 0
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return }
                buffer.append(chunk)
                appended = chunk.count
            }
            guard appended > 0 else { throw ReadError.truncatedDuringRead }
            position += Int64(appended)
            bytesRead += Int64(appended)
        }
    }

    /// Reject races rather than committing a mixture of two versions. Check
    /// both the open descriptor and the path (atomic replacement keeps the old
    /// descriptor valid). The caller retries from its last committed checkpoint.
    public func validateSnapshot() throws {
        guard try TranscriptFileSnapshot.read(descriptor: handle.fileDescriptor) == snapshot,
              try TranscriptFileSnapshot.read(at: path) == snapshot else {
            throw ReadError.changedDuringRead
        }
    }

    /// The append-only variant still checks the open descriptor as well as
    /// the path, but allows the writer to advance beyond this reader's EOF.
    @discardableResult
    public func validateAppendSnapshot(continuity: TranscriptFileContinuity) throws -> Int64 {
        let current = try TranscriptFileSnapshot.read(descriptor: handle.fileDescriptor)
        guard snapshot.hasSameIdentity(as: current), current.size >= snapshot.size else {
            throw ReadError.changedDuringRead
        }
        return try TranscriptSourceCheckpoint(snapshot: snapshot, offset: snapshot.size, continuity: continuity)
            .validateAppendOnlySource(at: path)
    }
}
