import Foundation

/// Reads selected top-level string fields without decoding large nested values.
/// Stops as soon as all requested fields (including nulls) have been encountered.
/// Unusual key order is supported by streaming past arrays/objects without
/// constructing their messages, tool results, images or other payloads.
public final class JSONMetadataReader {
    public enum ReadError: Error { case invalidJSON, oversizedField }
    public private(set) var bytesRead: Int64 = 0
    private let handle: FileHandle
    private let chunkSize: Int
    private var buffer = Data()
    private var position = 0
    private var pushedBack: UInt8?

    public init(path: String, chunkSize: Int = 16 * 1024) throws {
        precondition(chunkSize > 0)
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        self.chunkSize = chunkSize
    }

    deinit { try? handle.close() }

    public func readStringFields(_ fields: Set<String>) throws -> [String: String] {
        guard try nextNonWhitespace() == 0x7B else { throw ReadError.invalidJSON }
        var remaining = fields
        var result: [String: String] = [:]
        while !remaining.isEmpty {
            guard let first = try nextNonWhitespace() else { throw ReadError.invalidJSON }
            if first == 0x7D { return result }
            guard first == 0x22 else { throw ReadError.invalidJSON }
            let keyData = try value(startingWith: first, capture: true)
            guard let key = try JSONSerialization.jsonObject(with: keyData, options: [.fragmentsAllowed]) as? String,
                  try nextNonWhitespace() == 0x3A,
                  let valueStart = try nextNonWhitespace() else { throw ReadError.invalidJSON }
            let wanted = remaining.remove(key) != nil
            let data = try value(startingWith: valueStart, capture: wanted)
            if wanted, let text = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
                result[key] = text
            }
            if remaining.isEmpty { return result }
            guard let separator = try nextNonWhitespace() else { throw ReadError.invalidJSON }
            if separator == 0x7D { return result }
            guard separator == 0x2C else { throw ReadError.invalidJSON }
        }
        return result
    }

    private func value(startingWith first: UInt8, capture: Bool) throws -> Data {
        var result = Data()
        func append(_ byte: UInt8) throws {
            guard capture else { return }
            guard result.count < 1_048_576 else { throw ReadError.oversizedField }
            result.append(byte)
        }
        try append(first)
        var inString = first == 0x22
        var escaped = false
        var depth = (first == 0x7B || first == 0x5B) ? 1 : 0
        if depth == 0 && !inString {
            while let byte = try nextByte() {
                if byte == 0x2C || byte == 0x7D || byte == 0x5D {
                    pushedBack = byte
                    return result
                }
                try append(byte)
            }
            throw ReadError.invalidJSON
        }
        while let byte = try nextByte() {
            try append(byte)
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false; if depth == 0 { return result } }
            } else {
                switch byte {
                case 0x22: inString = true
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { return result }
                default: break
                }
            }
        }
        throw ReadError.invalidJSON
    }

    private func nextNonWhitespace() throws -> UInt8? {
        while let byte = try nextByte() {
            if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { return byte }
        }
        return nil
    }

    private func nextByte() throws -> UInt8? {
        if let byte = pushedBack { pushedBack = nil; return byte }
        if position == buffer.count {
            try Task.checkCancellation()
            // `FileHandle.read` is autoreleased; copy it into a pool-free
            // buffer so scanning a large document does not keep every chunk.
            var next = Data()
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: chunkSize) { next.append(chunk) }
            }
            buffer = next
            bytesRead += Int64(buffer.count)
            position = 0
            if buffer.isEmpty { return nil }
        }
        defer { position += 1 }
        return buffer[buffer.startIndex + position]
    }
}
