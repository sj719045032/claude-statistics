import Foundation
import ClaudeStatisticsKit

extension TranscriptParser {
    /// Lightweight transcript extraction for FTS indexing. Keep this separate from
    /// parseMessages so startup indexing does not pay UI transcript costs.
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        guard let reader = try? TranscriptFileReader(path: path, includeFinalLine: true) else { return [] }
        // A read error must reject the projection, not masquerade as EOF and
        // commit the prefix of a truncated/replaced transcript as a full index.
        return (try? parseSearchIndexMessages(nextLine: { try reader.readNext() })) ?? []
    }

    /// Internal entry that takes pre-loaded `Data`, used by the combined
    /// parse + FTS extract path (PR6) and by the public single-arg
    /// wrapper. Iterates byte-level over the file to avoid the prior
    /// full-`String(decoding:)` allocation, which on a 30 MB JSONL
    /// peaked at several multiples of the on-disk size.
    func parseSearchIndexMessages(fromData data: Data) -> [SearchIndexMessage] {
        var lineStart = data.startIndex
        return parseSearchIndexMessages(nextLine: {
            guard lineStart < data.endIndex else { return nil }
            let lineEnd = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineSlice = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            return lineSlice
        })
    }

    func parseSearchIndexMessages(nextLine: () throws -> Data?) rethrows -> [SearchIndexMessage] {
        var messages: [SearchIndexMessage] = []
        let timestamps = TranscriptTimestampParser()
        while let lineSlice = try nextLine() {
            guard !lineSlice.isEmpty else { continue }
            // Decode and project inside a pool: the decoded tree and the
            // bridged strings the projection walks are autoreleased, and the
            // projected `SearchIndexMessage`s escape as native Swift values.
            autoreleasepool {
                guard let entry = try? JSONSerialization.jsonObject(with: lineSlice) as? [String: Any] else { return }
                messages.append(contentsOf: Self.searchIndexProjection(
                    from: entry, recordID: "", timestamp: timestamps.date(entry["timestamp"] as? String)
                ).map(\.message))
            }
        }

        return messages
    }

    /// PR6: single-pass parse + FTS extract. Reads the file once, then
    /// shares the `Data` between the two byte-level iterators. Saves
    /// one full file IO and one full-`String(decoding:)` allocation
    /// per call.
    func parseSessionAndSearchIndex(at path: String) -> SessionParseResult {
        let signpostState = PerformanceTracer.begin("Claude.parseSessionAndSearchIndex")
        defer { PerformanceTracer.end("Claude.parseSessionAndSearchIndex", signpostState) }
        guard let data = FileManager.default.contents(atPath: path) else {
            return SessionParseResult(stats: SessionStats(), searchMessages: [])
        }
        let stats = parseSession(fromData: data, path: path)
        let messages = parseSearchIndexMessages(fromData: data)
        return SessionParseResult(stats: stats, searchMessages: messages)
    }

    /// A record is decoded once by the checkpoint parser, then projected into
    /// stats, preview and index. Stable IDs replace streaming revisions in FTS.
    static func searchIndexProjection(from entry: [String: Any], recordID: String,
                                      timestamp: Date?) -> [IdentifiedSearchIndexMessage] {
        let type = entry["type"] as? String ?? ""
        let message = entry["message"] as? [String: Any] ?? [:]
        let messageID = message["id"] as? String ?? recordID
        var result: [IdentifiedSearchIndexMessage] = []
        func add(_ id: String, _ role: String, _ text: String?) {
            guard let text, let cleaned = cleanSearchText(text) else { return }
            result.append(.init(id: id, message: .init(role: role, content: cleaned, timestamp: timestamp)))
        }
        switch type {
        case "queue-operation":
            if entry["operation"] as? String == "enqueue" { add("queue:\(recordID)", "user", entry["content"] as? String) }
        case "user", "human":
            add("user:\(entry["uuid"] as? String ?? recordID)", "user", rawMessageText(message))
        case "assistant":
            add("assistant:\(messageID)", "assistant", rawMessageText(message))
            for (index, item) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                let fallback = "\(recordID):\(index)"
                switch item["type"] as? String {
                case "tool_use":
                    add("tool:\(item["id"] as? String ?? fallback)", "tool", searchText(forRawToolUse: item))
                case "tool_result":
                    let text = item["content"].flatMap { extractToolResultText(AnyCodable($0)) }
                    add("result:\(item["tool_use_id"] as? String ?? fallback)", "tool", text.map { String($0.prefix(500)) })
                default: break
                }
            }
        default: break
        }
        return result
    }

    static func rawMessageText(_ message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        let texts = (message["content"] as? [[String: Any]] ?? []).compactMap {
            $0["type"] as? String == "text" ? $0["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func searchText(forRawToolUse tool: [String: Any]) -> String? {
        var parts: [String] = []
        if let name = tool["name"] as? String { parts.append(name) }

        if let dict = tool["input"] as? [String: Any] {
            for key in ["file_path", "path", "pattern"] {
                if let value = dict[key] as? String { parts.append(value) }
            }
            if let command = dict["command"] as? String { parts.append(String(command.prefix(500))) }
            if let content = dict["content"] as? String { parts.append(String(content.prefix(2_000))) }
            if let oldString = dict["old_string"] as? String { parts.append(String(oldString.prefix(1_000))) }
            if let newString = dict["new_string"] as? String { parts.append(String(newString.prefix(1_000))) }
        }

        return cleanSearchText(parts.joined(separator: "\n"))
    }
}
