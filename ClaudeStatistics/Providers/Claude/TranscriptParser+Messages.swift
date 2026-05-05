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

    /// Parse all messages from a JSONL file for transcript display.
    ///
    /// PR7: iterates the file byte-level instead of allocating the
    /// whole content as a `String` and splitting on "\n". For a 30 MB
    /// JSONL the prior path peaked at the file size in `Data` plus
    /// several multiples in `String` + `[String]` overhead; this
    /// version keeps just the source `Data` plus the produced
    /// `[TranscriptDisplayMessage]`.
    func parseMessages(at path: String) -> [TranscriptDisplayMessage] {
        let signpostState = PerformanceTracer.begin("Claude.parseMessages")
        defer { PerformanceTracer.end("Claude.parseMessages", signpostState) }
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()

        var messages: [TranscriptDisplayMessage] = []
        var seenMsgIds: Set<String> = []
        var seenToolIds: Set<String> = []
        var toolResults: [String: String] = [:]      // tool_use_id → result text
        var toolMsgIndices: [String: Int] = [:]       // tool_use_id → index in messages
        var index = 0

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineSlice = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            guard !lineSlice.isEmpty,
                  let entry = try? decoder.decode(TranscriptEntry.self, from: lineSlice) else { continue }

            switch entry.type {
            case "queue-operation":
                // Queued user messages (e.g. interrupted and re-sent)
                guard entry.operation == "enqueue" else { continue }
                guard let text = entry.content, let cleaned = Self.cleanUserDisplayText(text) else { continue }
                messages.append(TranscriptDisplayMessage(
                    id: "msg-\(index)", role: "user", text: cleaned, timestamp: entry.timestampDate
                ))
                index += 1

            case "user", "human":
                guard let text = Self.extractAllText(from: entry) else { continue }
                guard let cleaned = Self.cleanUserDisplayText(text) else { continue }

                // Skip pure image-path messages (image already shown by [Image #N] message)
                if cleaned.hasPrefix("[Image: source:") && cleaned.hasSuffix("]") { continue }

                // Extract image paths: [Image: source: /path] or [Image #N] → construct path
                let nsRange = NSRange(cleaned.startIndex..., in: cleaned)
                var imagePaths: [String] = []
                // Pattern 1: explicit path
                for m in Self.imagePathPattern.matches(in: cleaned, range: nsRange) {
                    if let r = Range(m.range(at: 1), in: cleaned) {
                        imagePaths.append(String(cleaned[r]))
                    }
                }
                // Pattern 2: [Image #N] → ~/.claude/image-cache/{sessionId}/{N}.png
                if imagePaths.isEmpty {
                    let sessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    let cacheDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/image-cache/\(sessionId)")
                    for m in Self.imageNumPattern.matches(in: cleaned, range: nsRange) {
                        if let r = Range(m.range(at: 1), in: cleaned) {
                            let num = String(cleaned[r])
                            let imgPath = (cacheDir as NSString).appendingPathComponent("\(num).png")
                            if FileManager.default.fileExists(atPath: imgPath) {
                                imagePaths.append(imgPath)
                            }
                        }
                    }
                }

                var msg = TranscriptDisplayMessage(
                    id: "msg-\(index)", role: "user", text: cleaned, timestamp: entry.timestampDate
                )
                msg.imagePaths = imagePaths
                messages.append(msg)
                index += 1

            case "assistant":
                guard let message = entry.message else { continue }
                let msgId = message.id ?? UUID().uuidString

                // Text content (dedup streaming)
                let textContent = Self.extractAllText(from: entry)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let text = textContent, !text.isEmpty {
                    if seenMsgIds.contains(msgId) {
                        if let i = messages.indices.last(where: { messages[$0].id == "text-\(msgId)" }) {
                            messages[i] = TranscriptDisplayMessage(
                                id: "text-\(msgId)", role: "assistant", text: text, timestamp: entry.timestampDate
                            )
                        }
                    } else {
                        seenMsgIds.insert(msgId)
                        messages.append(TranscriptDisplayMessage(
                            id: "text-\(msgId)", role: "assistant", text: text, timestamp: entry.timestampDate
                        ))
                    }
                }

                // Tool use + tool result content items
                if let items = message.content {
                    for item in items {
                        if case .toolUse(let tc) = item {
                            let toolId = tc.id ?? "tool-\(index)"
                            guard !seenToolIds.contains(toolId) else { continue }
                            seenToolIds.insert(toolId)

                            let name = tc.name ?? "unknown"
                            let (summary, detail) = Self.toolSummaryAndDetail(name: name, input: tc.input)
                            let msgIdx = messages.count
                            var msg = TranscriptDisplayMessage(
                                id: "tool-\(toolId)", role: "tool", text: summary,
                                timestamp: entry.timestampDate, toolName: name, toolDetail: detail
                            )
                            // Edit tool: store old/new strings for TextDiffView
                            if name == "Edit", let dict = tc.input?.value as? [String: Any] {
                                msg.editOldString = dict["old_string"] as? String
                                msg.editNewString = dict["new_string"] as? String
                            }
                            messages.append(msg)
                            toolMsgIndices[toolId] = msgIdx
                            index += 1
                        }

                        if case .toolResult(let tr) = item, let toolId = tr.toolUseId {
                            if let resultText = Self.extractToolResultText(tr.content) {
                                toolResults[toolId] = resultText
                            }
                        }
                    }
                }

            default:
                continue
            }
        }

        // Link tool results to tool messages that don't already have detail from input
        for (toolId, result) in toolResults {
            guard let msgIdx = toolMsgIndices[toolId], msgIdx < messages.count else { continue }
            let msg = messages[msgIdx]
            if msg.toolDetail == nil || msg.toolDetail!.isEmpty {
                messages[msgIdx] = TranscriptDisplayMessage(
                    id: msg.id, role: msg.role, text: msg.text,
                    timestamp: msg.timestamp, toolName: msg.toolName, toolDetail: result
                )
            }
        }

        return messages
    }

    // MARK: - Tool summary & detail extraction

    /// Returns (summary line, detail content) for a tool call
    fileprivate static func toolSummaryAndDetail(name: String, input: AnyCodable?) -> (String, String?) {
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
            for (_, v) in dict {
                if let s = v as? String, !s.isEmpty {
                    return (s.count > 120 ? String(s.prefix(120)) + "…" : s, nil)
                }
            }
            return ("", nil)
        }
    }
}
