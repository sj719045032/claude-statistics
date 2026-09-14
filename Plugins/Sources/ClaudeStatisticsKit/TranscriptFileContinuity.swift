import Foundation
import CryptoKit

/// A bounded continuity check for append-only sources. Metadata detects
/// same-size rewrites/replacements; these boundary hashes also detect common
/// truncate-and-regrow writes. They are not a hash of the entire old history.
/// Providers with arbitrary in-place mutation must use snapshot replacement.
public struct TranscriptFileContinuity: Codable, Equatable, Sendable {
    private let digest: Data

    public static func sampledBytes(upTo offset: Int64) -> Int64 { min(2048, max(0, offset)) }

    public static func read(at path: String, upTo offset: Int64) throws -> Self {
        guard offset >= 0 else { throw TranscriptFileReader.ReadError.invalidOffset }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let firstCount = Int(min(1024, offset))
        let lastStart = max(Int64(firstCount), offset - 1024)
        let lastCount = Int(offset - lastStart)
        let first = try file.read(upToCount: firstCount) ?? Data()
        try file.seek(toOffset: UInt64(lastStart))
        let last = try file.read(upToCount: lastCount) ?? Data()
        guard first.count == firstCount, last.count == lastCount else {
            throw TranscriptFileReader.ReadError.truncatedDuringRead
        }
        var hash = SHA256()
        hash.update(data: first)
        hash.update(data: last)
        return Self(digest: Data(hash.finalize()))
    }
}
