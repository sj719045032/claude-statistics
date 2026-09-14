import Foundation
import ClaudeStatisticsKit

extension TranscriptParser {
    /// Regex to extract image path from [Image: source: /path/to/file.png]
    fileprivate static let imagePathPattern = try! NSRegularExpression(
        pattern: "\\[Image: source: ([^\\]]+)\\]",
        options: []
    )
    /// Regex to extract image number from [Image #N]
    fileprivate static let imageNumPattern = try! NSRegularExpression(
        pattern: "\\[Image #(\\d+)\\]",
        options: []
    )

    /// What a single record contributes before cross-record linking. Shared by
    /// the whole-file parse, the outline pass and page materialization so all
    /// three agree on row ids, ordering and content.
    enum RecordRow {
        /// Id is assigned by the linker from the running row counter.
        case user(TranscriptDisplayMessage)
        case assistantText(TranscriptDisplayMessage)
        case toolUse(toolId: String, TranscriptDisplayMessage)
        case toolResult(toolId: String, text: String)
    }

    /// Cross-record identity, dedup and result routing. It owns the row
    /// bookkeeping and hands back positions; each caller owns its own payload
    /// storage (full messages for a parse, byte locators for an outline).
    struct RowLinker {
        struct Slot {
            let id: String
            let role: String
            let toolName: String?
            /// The row shows its tool result because the call itself carried
            /// no detail. Decided when the row is created, so an outline can
            /// cite the result record without materializing the message.
            let wantsResult: Bool
        }

        enum Outcome {
            case appended(Slot)
            /// A streaming revision of an assistant text row already emitted.
            case revised(index: Int)
            /// A duplicate `tool_use` id; the first occurrence owns the row.
            case skipped
        }

        private var count = 0
        private var index = 0
        private var textRowIndices: [String: Int] = [:]
        private var toolResultTargets: [String: Int] = [:]
        private var seenToolIds: Set<String> = []

        /// Accepts the rows that create or revise a display row. A
        /// `.toolResult` row carries no row of its own — route it through
        /// `resultTarget(for:)` instead.
        mutating func accept(_ row: RecordRow) -> Outcome {
            switch row {
            case .user:
                let id = "msg-\(index)"
                index += 1
                count += 1
                return .appended(Slot(id: id, role: "user", toolName: nil, wantsResult: false))

            case .assistantText(let message):
                if let existing = textRowIndices[message.id] { return .revised(index: existing) }
                textRowIndices[message.id] = count
                count += 1
                return .appended(Slot(id: message.id, role: "assistant", toolName: nil, wantsResult: false))

            case .toolUse(let toolId, let message):
                guard !seenToolIds.contains(toolId) else { return .skipped }
                seenToolIds.insert(toolId)
                let wantsResult = message.toolDetail?.isEmpty ?? true
                if wantsResult { toolResultTargets[toolId] = count }
                count += 1
                index += 1
                return .appended(Slot(
                    id: message.id, role: "tool", toolName: message.toolName,
                    wantsResult: wantsResult
                ))

            case .toolResult:
                return .skipped
            }
        }

        /// Row that should display `toolId`'s result, or nil when the call
        /// already carried its own detail or produced no row.
        func resultTarget(for toolId: String) -> Int? { toolResultTargets[toolId] }
    }

    /// Map one decoded record to the rows it contributes. `recordOffset` only
    /// backs the fallback id for a malformed `tool_use` without an id; it keeps
    /// that id positional so a page load reproduces it without replaying the
    /// whole file.
    static func recordRows(from entry: TranscriptEntry, recordOffset: Int64,
                           sessionId: String) -> [RecordRow] {
        switch entry.type {
        case "queue-operation":
            // Queued user messages (e.g. interrupted and re-sent)
            guard entry.operation == "enqueue",
                  let text = entry.content,
                  let cleaned = cleanUserDisplayText(text) else { return [] }
            return [.user(TranscriptDisplayMessage(
                id: "", role: "user", text: cleaned, timestamp: entry.timestampDate
            ))]

        case "user", "human":
            guard let text = extractAllText(from: entry),
                  let cleaned = cleanUserDisplayText(text) else { return [] }
            // Skip pure image-path messages (image already shown by [Image #N] message)
            if cleaned.hasPrefix("[Image: source:") && cleaned.hasSuffix("]") { return [] }

            var msg = TranscriptDisplayMessage(
                id: "", role: "user", text: cleaned, timestamp: entry.timestampDate
            )
            msg.imagePaths = imagePaths(in: cleaned, sessionId: sessionId)
            return [.user(msg)]

        case "assistant":
            guard let message = entry.message else { return [] }
            var rows: [RecordRow] = []

            // Text content (dedup streaming). A record without a message id
            // cannot be revised later, so it gets a positional id.
            let msgId = message.id ?? "at-\(recordOffset)"
            let textContent = extractAllText(from: entry)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text = textContent, !text.isEmpty {
                rows.append(.assistantText(TranscriptDisplayMessage(
                    id: "text-\(msgId)", role: "assistant", text: text, timestamp: entry.timestampDate
                )))
            }

            // Tool use + tool result content items
            for (position, item) in (message.content ?? []).enumerated() {
                if case .toolUse(let tc) = item {
                    let toolId = tc.id ?? "at-\(recordOffset)-\(position)"
                    let name = tc.name ?? "unknown"
                    let (summary, detail) = toolSummaryAndDetail(name: name, input: tc.input)
                    var msg = TranscriptDisplayMessage(
                        id: "tool-\(toolId)", role: "tool", text: summary,
                        timestamp: entry.timestampDate, toolName: name, toolDetail: detail
                    )
                    // Edit tool: store old/new strings for TextDiffView
                    if name == "Edit", let dict = tc.input?.value as? [String: Any] {
                        msg.editOldString = dict["old_string"] as? String
                        msg.editNewString = dict["new_string"] as? String
                    }
                    rows.append(.toolUse(toolId: toolId, msg))
                }

                if case .toolResult(let tr) = item, let toolId = tr.toolUseId,
                   let resultText = extractToolResultText(tr.content) {
                    rows.append(.toolResult(toolId: toolId, text: resultText))
                }
            }
            return rows

        default:
            return []
        }
    }

    private static func imagePaths(in cleaned: String, sessionId: String) -> [String] {
        // Extract image paths: [Image: source: /path] or [Image #N] → construct path
        let nsRange = NSRange(cleaned.startIndex..., in: cleaned)
        var imagePaths: [String] = []
        // Pattern 1: explicit path
        for m in imagePathPattern.matches(in: cleaned, range: nsRange) {
            if let r = Range(m.range(at: 1), in: cleaned) {
                imagePaths.append(String(cleaned[r]))
            }
        }
        guard imagePaths.isEmpty else { return imagePaths }

        // Pattern 2: [Image #N] → ~/.claude/image-cache/{sessionId}/{N}.png
        let cacheDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/image-cache/\(sessionId)")
        for m in imageNumPattern.matches(in: cleaned, range: nsRange) {
            if let r = Range(m.range(at: 1), in: cleaned) {
                let num = String(cleaned[r])
                let imgPath = (cacheDir as NSString).appendingPathComponent("\(num).png")
                if FileManager.default.fileExists(atPath: imgPath) {
                    imagePaths.append(imgPath)
                }
            }
        }
        return imagePaths
    }

    /// Replace a row's id while keeping every other field. Row ids come from
    /// the linker, not from the record the fields were decoded from.
    static func withId(_ id: String, _ message: TranscriptDisplayMessage) -> TranscriptDisplayMessage {
        var copy = TranscriptDisplayMessage(
            id: id, role: message.role, text: message.text, timestamp: message.timestamp,
            toolName: message.toolName, toolDetail: message.toolDetail
        )
        copy.editOldString = message.editOldString
        copy.editNewString = message.editNewString
        copy.imagePaths = message.imagePaths
        return copy
    }

    /// Parse all messages from a JSONL file for transcript display.
    ///
    /// PR7: iterates the file byte-level instead of allocating the
    /// whole content as a `String` and splitting on "\n". For a 30 MB
    /// JSONL the prior path peaked at the file size in `Data` plus
    /// several multiples in `String` + `[String]` overhead; this
    /// version keeps just the source `Data` plus the produced
    /// `[TranscriptDisplayMessage]`.
    func parseMessages(at path: String) -> [TranscriptDisplayMessage] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let sessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return parseMessages(fromData: data, sessionId: sessionId)
    }

    func parseMessages(fromData data: Data, sessionId: String) -> [TranscriptDisplayMessage] {
        let signpostState = PerformanceTracer.begin("Claude.parseMessages")
        defer { PerformanceTracer.end("Claude.parseMessages", signpostState) }
        let decoder = JSONDecoder()

        var linker = TranscriptParser.RowLinker()
        var messages: [TranscriptDisplayMessage] = []
        var toolResults: [String: String] = [:]      // tool_use_id → result text

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineSlice = data[lineStart..<lineEnd]
            let recordOffset = Int64(data.distance(from: data.startIndex, to: lineStart))
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            // Row extraction bridges to Foundation (regex matching over the
            // message text), which autoreleases. Drain per record or the whole
            // file's bridged strings stay alive until the parse returns.
            autoreleasepool {
                guard !lineSlice.isEmpty,
                      let entry = try? decoder.decode(TranscriptEntry.self, from: lineSlice) else { return }

                for row in TranscriptParser.recordRows(from: entry, recordOffset: recordOffset, sessionId: sessionId) {
                    if case .toolResult(let toolId, let text) = row {
                        toolResults[toolId] = text
                        continue
                    }
                    guard let message = row.message else { continue }
                    switch linker.accept(row) {
                    case .appended(let slot):
                        messages.append(TranscriptParser.withId(slot.id, message))
                    case .revised(let index):
                        messages[index] = TranscriptParser.withId(messages[index].id, message)
                    case .skipped:
                        continue
                    }
                }
            }
        }

        // Link tool results to tool messages that don't already have detail from input
        for (toolId, result) in toolResults {
            guard let index = linker.resultTarget(for: toolId), index < messages.count else { continue }
            let msg = messages[index]
            messages[index] = TranscriptDisplayMessage(
                id: msg.id, role: msg.role, text: msg.text,
                timestamp: msg.timestamp, toolName: msg.toolName, toolDetail: result
            )
        }

        return messages
    }

    // MARK: - Tool summary & detail extraction

    /// Returns (summary line, detail content) for a tool call
    static func toolSummaryAndDetail(name: String, input: AnyCodable?) -> (String, String?) {
        guard let dict = input?.value as? [String: Any] else {
            return (input?.stringValue ?? "", nil)
        }

        switch name {
        case "Write":
            let path = dict["file_path"] as? String ?? ""
            let content = dict["content"] as? String
            return (path, content)

        case "Edit":
            let path = dict["file_path"] as? String ?? ""
            // old/new strings stored separately on DisplayMessage for TextDiffView
            return (path, nil)

        case "Bash":
            let cmd = dict["command"] as? String ?? ""
            let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
            let summary = firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
            // Full command as detail if multi-line; result will be appended later
            let detail = cmd.contains("\n") ? cmd : nil
            return (summary, detail)

        case "Read":
            let path = dict["file_path"] as? String ?? ""
            var extras: [String] = []
            if let offset = dict["offset"] as? Int { extras.append("L\(offset)") }
            if let limit = dict["limit"] as? Int { extras.append("+\(limit)") }
            let summary = extras.isEmpty ? path : "\(path) (\(extras.joined(separator: " ")))"
            return (summary, nil) // detail filled from result

        case "Grep":
            let pattern = dict["pattern"] as? String ?? ""
            let path = dict["path"] as? String
            let summary = path != nil ? "\(pattern) in \(path!)" : pattern
            return (summary, nil)

        case "Glob":
            let pattern = dict["pattern"] as? String ?? ""
            return (pattern, nil)

        case "Agent":
            let desc = dict["description"] as? String ?? ""
            let subType = dict["subagent_type"] as? String
            let summary = subType != nil ? "[\(subType!)] \(desc)" : desc
            return (summary, nil)

        default:
            // Generic: show file_path or first string value
            if let path = dict["file_path"] as? String { return (path, nil) }
            if let cmd = dict["command"] as? String {
                let first = cmd.components(separatedBy: "\n").first ?? cmd
                return (first.count > 120 ? String(first.prefix(120)) + "…" : first, nil)
            }
            // Sorted, not `dict.first` — dictionary order is not stable across
            // decodes, and the outline pass and a later page load must produce
            // the same summary for the same record.
            for key in dict.keys.sorted() {
                if let s = dict[key] as? String, !s.isEmpty {
                    return (s.count > 120 ? String(s.prefix(120)) + "…" : s, nil)
                }
            }
            return ("", nil)
        }
    }
}

extension TranscriptParser.RecordRow {
    /// The display message a row carries, or nil for a bare tool result.
    var message: TranscriptDisplayMessage? {
        switch self {
        case .user(let m), .assistantText(let m), .toolUse(_, let m): return m
        case .toolResult: return nil
        }
    }
}
