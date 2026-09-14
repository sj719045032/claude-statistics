import Foundation
import ClaudeStatisticsKit

/// How `session_cache.parser_checkpoint` stores a checkpoint: `CSPC`, a
/// little-endian UInt32 header length, the checkpoint as JSON with an empty
/// state, then the provider's state bytes as they are. Whole-JSON rows from
/// earlier builds (state as base64) still decode. Keeping the state out of the
/// JSON saves base64-encoding it on every commit and decoding it on every load,
/// and lets a commit's compare-and-swap read the ID without touching the state.
enum ParseCheckpointCoding {
    private static let magic = Array("CSPC".utf8)

    static func encode(_ checkpoint: SessionParseCheckpoint) throws -> Data {
        let header = try JSONEncoder().encode(SessionParseCheckpoint(
            parserRevision: checkpoint.parserRevision, sources: checkpoint.sources, state: Data(), id: checkpoint.id
        ))
        var data = Data(magic)
        withUnsafeBytes(of: UInt32(header.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(checkpoint.state)
        return data
    }

    static func decode(_ data: Data) -> SessionParseCheckpoint? {
        guard let parsed = parsedHeader(in: data) else {
            return try? JSONDecoder().decode(SessionParseCheckpoint.self, from: data)
        }
        return SessionParseCheckpoint(parserRevision: parsed.header.parserRevision, sources: parsed.header.sources,
                                      state: data.subdata(in: parsed.stateStart..<data.endIndex), id: parsed.header.id)
    }

    static func decodeID(_ data: Data) -> UUID? {
        if let parsed = parsedHeader(in: data) { return parsed.header.id }
        return (try? JSONDecoder().decode(SessionParseCheckpoint.self, from: data))?.id
    }

    private static func parsedHeader(in data: Data) -> (header: SessionParseCheckpoint, stateStart: Data.Index)? {
        guard data.starts(with: magic), data.count >= magic.count + 4 else { return nil }
        let lengthStart = data.startIndex + magic.count
        let length = data[lengthStart..<lengthStart + 4].withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        let headerStart = lengthStart + 4
        guard length <= data.endIndex - headerStart,
              let header = try? JSONDecoder().decode(SessionParseCheckpoint.self,
                                                     from: data[headerStart..<headerStart + length]) else { return nil }
        return (header, headerStart + length)
    }
}
