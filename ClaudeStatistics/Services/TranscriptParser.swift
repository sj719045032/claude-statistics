import Foundation

final class TranscriptParser {
    static let shared = TranscriptParser()

    private init() {}

    /// Per-message accumulated data (streaming produces multiple entries; we keep the last/final one)
    private struct MessageAccum {
        var model: String
        var timestamp: Date?
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheCreationTotalTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreation5mTokens: Int = 0
        var cacheCreation1hTokens: Int = 0
    }

    func parseSession(at path: String) -> SessionStats {
        var stats = SessionStats()

        guard let data = FileManager.default.contents(atPath: path) else {
            return stats
        }

        // Store per-message data; last entry wins (streaming sends partial then final usage)
        var messageData: [String: MessageAccum] = [:]
        var seenToolUseIds: Set<String> = []
        var toolUseTimes: [(Date, String)] = []   // (sliceStart, toolName)
        var userMessageTimes: [Date] = []         // sliceStarts for user messages
        let cal = Calendar.current
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFmtFallback = ISO8601DateFormatter()
        isoFmtFallback.formatOptions = [.withInternetDateTime]

        func parseTimestamp(_ str: String?) -> Date? {
            guard let str else { return nil }
            return isoFmt.date(from: str) ?? isoFmtFallback.date(from: str)
        }

        /// Compute fiveMinSlice key: truncate to 5-minute boundary, with midnight hour attributed to previous day
        func fiveMinKey(for date: Date) -> Date {
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            comps.minute = ((comps.minute ?? 0) / 5) * 5
            comps.second = 0
            comps.nanosecond = 0
            guard let result = cal.date(from: comps) else { return date }
            if comps.hour == 0 {
                return cal.date(byAdding: .hour, value: -1, to: result)!
            }
            return result
        }

        let assistantMarker = Data("\"assistant\"".utf8)
        let userMarker = Data("\"user\"".utf8)
        let humanMarker = Data("\"human\"".utf8)

        // Scan Data directly — avoid String conversion and splitting
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineSlice = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            guard lineSlice.count > 10 else { continue }

            // Pre-filter: skip lines without user/assistant type
            let hasAssistant = lineSlice.range(of: assistantMarker) != nil
            let hasUser = !hasAssistant && (lineSlice.range(of: userMarker) != nil || lineSlice.range(of: humanMarker) != nil)
            guard hasAssistant || hasUser else { continue }

            guard let json = try? JSONSerialization.jsonObject(with: lineSlice) as? [String: Any] else { continue }
            let entryType = json["type"] as? String ?? ""
            let timestamp = parseTimestamp(json["timestamp"] as? String)

            // Track timestamps
            if let date = timestamp {
                if stats.startTime == nil || date < stats.startTime! { stats.startTime = date }
                if stats.endTime == nil || date > stats.endTime! { stats.endTime = date }
            }

            if entryType == "user" || entryType == "human" {
                stats.userMessageCount += 1
                if let ts = timestamp { userMessageTimes.append(fiveMinKey(for: ts)) }
                // Track last user text for "Last Prompt"
                if let message = json["message"] as? [String: Any] {
                    let text: String? = (message["content"] as? String)
                        ?? (message["content"] as? [[String: Any]])?.compactMap({ $0["text"] as? String }).joined(separator: "\n")
                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        stats.lastPrompt = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
                    }
                }

            } else if entryType == "assistant" {
                guard let message = json["message"] as? [String: Any] else { continue }
                let msgId = message["id"] as? String ?? UUID().uuidString
                let isFirstOccurrence = messageData[msgId] == nil

                if isFirstOccurrence {
                    stats.assistantMessageCount += 1
                }

                let model = message["model"] as? String
                let isSynthetic = model == "<synthetic>"
                let currentModel = isSynthetic ? stats.model : (model ?? stats.model)
                if let model, model != "Unknown", !isSynthetic {
                    stats.model = model
                }

                if let usage = message["usage"] as? [String: Any] {
                    let inputTokens = usage["input_tokens"] as? Int ?? 0
                    let outputTokens = usage["output_tokens"] as? Int ?? 0
                    let cacheCreationTotal = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheCreation = usage["cache_creation"] as? [String: Any]

                    let contextSize = inputTokens + cacheCreationTotal + cacheReadTokens
                    if contextSize > 0 { stats.contextTokens = contextSize }

                    messageData[msgId] = MessageAccum(
                        model: currentModel,
                        timestamp: timestamp,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheCreationTotalTokens: cacheCreationTotal,
                        cacheReadTokens: cacheReadTokens,
                        cacheCreation5mTokens: cacheCreation?["ephemeral_5m_input_tokens"] as? Int ?? 0,
                        cacheCreation1hTokens: cacheCreation?["ephemeral_1h_input_tokens"] as? Int ?? 0
                    )

                    // Track tool uses
                    if let content = message["content"] as? [[String: Any]] {
                        for item in content {
                            if item["type"] as? String == "tool_use", let toolName = item["name"] as? String {
                                let toolId = item["id"] as? String ?? UUID().uuidString
                                if !seenToolUseIds.contains(toolId) {
                                    seenToolUseIds.insert(toolId)
                                    if let ts = timestamp { toolUseTimes.append((fiveMinKey(for: ts), toolName)) }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Merge subagent tokens into messageData BEFORE aggregation
        // This ensures global dedup: main session + all subagents share one dictionary
        let sessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let subagentDir = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(sessionId)
            .appending("/subagents")

        // Record main session message IDs before subagent merge
        let mainMessageIds = Set(messageData.keys)

        if FileManager.default.fileExists(atPath: subagentDir),
           let subFiles = try? FileManager.default.contentsOfDirectory(atPath: subagentDir) {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]

            for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                let subPath = (subagentDir as NSString).appendingPathComponent(subFile)
                guard let subData = FileManager.default.contents(atPath: subPath) else { continue }

                // Use JSONSerialization instead of JSONDecoder for ~5x speed improvement
                var lineStart = subData.startIndex
                while lineStart < subData.endIndex {
                    let lineEnd = subData[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? subData.endIndex
                    let lineSlice = subData[lineStart..<lineEnd]
                    lineStart = lineEnd < subData.endIndex ? subData.index(after: lineEnd) : subData.endIndex
                    guard lineSlice.count > 10 else { continue }

                    // Pre-filter: skip non-assistant lines without parsing JSON
                    guard lineSlice.range(of: Data("\"assistant\"".utf8), in: lineSlice.startIndex..<lineSlice.endIndex) != nil else { continue }

                    guard let json = try? JSONSerialization.jsonObject(with: lineSlice) as? [String: Any],
                          json["type"] as? String == "assistant",
                          let message = json["message"] as? [String: Any],
                          let msgId = message["id"] as? String,
                          !mainMessageIds.contains(msgId),
                          let usage = message["usage"] as? [String: Any] else { continue }

                    let model = message["model"] as? String ?? stats.model
                    if model == "<synthetic>" { continue }

                    let cacheCreation = usage["cache_creation"] as? [String: Any]
                    let timestamp: Date? = (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) ?? isoFallback.date(from: $0) }

                    messageData[msgId] = MessageAccum(
                        model: model,
                        timestamp: timestamp,
                        inputTokens: usage["input_tokens"] as? Int ?? 0,
                        outputTokens: usage["output_tokens"] as? Int ?? 0,
                        cacheCreationTotalTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                        cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                        cacheCreation5mTokens: cacheCreation?["ephemeral_5m_input_tokens"] as? Int ?? 0,
                        cacheCreation1hTokens: cacheCreation?["ephemeral_1h_input_tokens"] as? Int ?? 0
                    )
                }
            }
        }

        // Aggregate all messages (main + subagent) into fiveMinSlices (single source of truth)
        for (_, accum) in messageData {
            if let ts = accum.timestamp {
                let sliceKey = fiveMinKey(for: ts)
                var slice = stats.fiveMinSlices[sliceKey] ?? SessionStats.DaySlice()
                slice.totalInputTokens += accum.inputTokens
                slice.totalOutputTokens += accum.outputTokens
                slice.cacheCreationTotalTokens += accum.cacheCreationTotalTokens
                slice.cacheReadTokens += accum.cacheReadTokens
                slice.cacheCreation5mTokens += accum.cacheCreation5mTokens
                slice.cacheCreation1hTokens += accum.cacheCreation1hTokens
                slice.messageCount += 1
                var ms = slice.modelBreakdown[accum.model, default: ModelTokenStats()]
                ms.inputTokens += accum.inputTokens
                ms.outputTokens += accum.outputTokens
                ms.cacheCreationTotalTokens += accum.cacheCreationTotalTokens
                ms.cacheReadTokens += accum.cacheReadTokens
                ms.cacheCreation5mTokens += accum.cacheCreation5mTokens
                ms.cacheCreation1hTokens += accum.cacheCreation1hTokens
                ms.messageCount += 1
                slice.modelBreakdown[accum.model] = ms
                stats.fiveMinSlices[sliceKey] = slice
            }
        }

        // Assign user messages and tool uses to fiveMin slices
        for time in userMessageTimes {
            stats.fiveMinSlices[time, default: SessionStats.DaySlice()].messageCount += 1
        }
        for (time, toolName) in toolUseTimes {
            stats.fiveMinSlices[time, default: SessionStats.DaySlice()].toolUseCounts[toolName, default: 0] += 1
        }

        DiagnosticLogger.shared.parsingSummary(
            file: path,
            totalLines: messageData.count + stats.userMessageCount,
            skippedLines: 0,
            messages: stats.messageCount,
            tokens: stats.totalTokens
        )

        return stats
    }

    /// Parse JSONL into time-bucketed trend data points for chart display
    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return []
        }
        let content = String(decoding: data, as: UTF8.self)

        let decoder = JSONDecoder()
        let lines = content.components(separatedBy: "\n")

        // Per-message: track last entry (streaming dedup), keyed by message ID
        struct MsgData {
            var timestamp: Date
            var model: String
            var inputTokens: Int = 0
            var outputTokens: Int = 0
            var cacheCreationTotalTokens: Int = 0
            var cacheReadTokens: Int = 0
            var cacheCreation5mTokens: Int = 0
            var cacheCreation1hTokens: Int = 0
        }
        var messageData: [String: MsgData] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            guard let entry = try? decoder.decode(TranscriptEntry.self, from: lineData),
                  entry.type == "assistant",
                  let message = entry.message,
                  let usage = message.usage,
                  let timestamp = entry.timestampDate else { continue }

            let isSynthetic = message.model == "<synthetic>"
            guard !isSynthetic else { continue }

            let msgId = message.id ?? UUID().uuidString
            let model = message.model ?? "Unknown"

            messageData[msgId] = MsgData(
                timestamp: timestamp,
                model: model,
                inputTokens: usage.inputTokens ?? 0,
                outputTokens: usage.outputTokens ?? 0,
                cacheCreationTotalTokens: usage.cacheCreationInputTokens ?? 0,
                cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                cacheCreation5mTokens: usage.cacheCreation?.ephemeral5mInputTokens ?? 0,
                cacheCreation1hTokens: usage.cacheCreation?.ephemeral1hInputTokens ?? 0
            )
        }

        // Bucket by granularity
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]
        for (_, msg) in messageData {
            let bucket = granularity.bucketStart(for: msg.timestamp)
            let tokens = msg.inputTokens + msg.outputTokens + msg.cacheCreationTotalTokens + msg.cacheReadTokens
            let cost = ModelPricing.estimateCost(
                model: msg.model,
                inputTokens: msg.inputTokens,
                outputTokens: msg.outputTokens,
                cacheCreation5mTokens: msg.cacheCreation5mTokens,
                cacheCreation1hTokens: msg.cacheCreation1hTokens,
                cacheCreationTotalTokens: msg.cacheCreationTotalTokens,
                cacheReadTokens: msg.cacheReadTokens
            )
            var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
            existing.tokens += tokens
            existing.cost += cost
            buckets[bucket] = existing
        }

        // Sort by time, then accumulate into running totals
        let sorted = buckets.sorted { $0.key < $1.key }
        var cumTokens = 0
        var cumCost = 0.0
        return sorted.map { (time, val) in
            cumTokens += val.tokens
            cumCost += val.cost
            return TrendDataPoint(time: time, tokens: cumTokens, cost: cumCost)
        }
    }

    /// Parse only basic info (fast, reads first few lines)
    struct QuickStats: Codable {
        var startTime: Date?
        var model: String?
        var topic: String?
        var lastPrompt: String?
        var sessionName: String?
        var messageCount: Int = 0
        var userMessageCount: Int = 0
        var totalTokens: Int = 0
        var estimatedCost: Double = 0
    }

    func parseSessionQuick(at path: String) -> QuickStats {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return QuickStats()
        }
        defer { handle.closeFile() }

        var quick = QuickStats()
        var totalInput = 0
        var totalOutput = 0
        var cacheCreate = 0
        var cacheRead = 0

        // Read first 16KB for quick info
        let data = handle.readData(ofLength: 16384)
        let content = String(decoding: data, as: UTF8.self)

        let decoder = JSONDecoder()
        let lines = content.components(separatedBy: "\n")
        // Store per-message usage; last entry wins (streaming partial → final)
        var msgUsage: [String: (input: Int, output: Int, cacheCreate: Int, cacheRead: Int)] = [:]
        var countedMsgIds: Set<String> = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            guard let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }

            if quick.startTime == nil, let date = entry.timestampDate {
                quick.startTime = date
            }

            if (entry.type == "user" || entry.type == "human"), quick.topic == nil {
                if let text = Self.extractUserText(from: entry) {
                    quick.topic = Self.cleanTopic(text)
                }
            }

            if entry.type == "assistant" {
                let msgId = entry.message?.id ?? UUID().uuidString

                if !countedMsgIds.contains(msgId) {
                    countedMsgIds.insert(msgId)
                    if quick.model == nil, let m = entry.message?.model {
                        quick.model = m
                    }
                    quick.messageCount += 1
                }

                // Overwrite with latest entry (last has final output tokens)
                if let usage = entry.message?.usage {
                    msgUsage[msgId] = (
                        input: usage.inputTokens ?? 0,
                        output: usage.outputTokens ?? 0,
                        cacheCreate: usage.cacheCreationInputTokens ?? 0,
                        cacheRead: usage.cacheReadInputTokens ?? 0
                    )
                }
            } else if entry.type == "human" {
                quick.messageCount += 1
                quick.userMessageCount += 1
            }
        }

        // Sum final per-message usage
        for (_, u) in msgUsage {
            totalInput += u.input
            totalOutput += u.output
            cacheCreate += u.cacheCreate
            cacheRead += u.cacheRead
        }

        // Estimate from file size ratio (head data vs full file)
        let fileSize = handle.seekToEndOfFile()
        let headSize = min(Int(fileSize), 16384)
        let ratio = headSize > 0 && fileSize > UInt64(headSize) ? Double(fileSize) / Double(headSize) : 1.0

        quick.totalTokens = Int(Double(totalInput + totalOutput + cacheCreate + cacheRead) * ratio)
        quick.messageCount = max(quick.messageCount, Int(Double(quick.messageCount) * ratio))

        // Estimate cost from head tokens (more accurate than extrapolation)
        if let model = quick.model {
            quick.estimatedCost = ModelPricing.estimateCost(
                model: model,
                inputTokens: Int(Double(totalInput) * ratio),
                outputTokens: Int(Double(totalOutput) * ratio),
                cacheCreation5mTokens: 0,
                cacheCreation1hTokens: Int(Double(cacheCreate) * ratio),
                cacheCreationTotalTokens: Int(Double(cacheCreate) * ratio),
                cacheReadTokens: Int(Double(cacheRead) * ratio)
            )
        }

        // Read last user message from end of file
        // Prefer actual user message over last-prompt (which isn't written after every message)
        let tailSize: UInt64 = min(fileSize, 512 * 1024)
        let tailOffset = fileSize - tailSize
        handle.seek(toFileOffset: tailOffset)
        let tailData = handle.readData(ofLength: Int(tailSize))
        do {
            let tailContent = String(decoding: tailData, as: UTF8.self)
            let tailLines = tailContent.components(separatedBy: "\n")
            var foundPrompt = false
            var latestSlug: String?
            var latestCustomTitle: String?
            for line in tailLines.reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }

                // Extract session name (customTitle from /rename, or auto-generated slug)
                if latestCustomTitle == nil, let ct = entry.customTitle {
                    latestCustomTitle = ct
                }
                if latestSlug == nil, let s = entry.slug {
                    latestSlug = s
                }

                if !foundPrompt, entry.type == "user" || entry.type == "human" {
                    if let text = Self.extractUserText(from: entry) {
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            quick.lastPrompt = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
                            foundPrompt = true
                        }
                    }
                }
            }
            quick.sessionName = latestCustomTitle ?? latestSlug
        }  // end do

        return quick
    }

    // MARK: - Parse messages for transcript display

    struct DisplayMessage: Identifiable {
        let id: String
        let role: String      // "user", "assistant", or "tool"
        let text: String      // summary line (file path, command, etc.)
        let timestamp: Date?
        var toolName: String?  // non-nil for tool call entries
        var toolDetail: String? // expandable content (code, output, etc.)
        var editOldString: String? // Edit tool: original text (for diff view)
        var editNewString: String? // Edit tool: replacement text (for diff view)
        var imagePaths: [String] = [] // image file paths for inline display
    }

    /// Regex to extract image path from [Image: source: /path/to/file.png]
    private static let imagePathPattern = try! NSRegularExpression(
        pattern: "\\[Image: source: ([^\\]]+)\\]",
        options: []
    )
    /// Regex to extract image number from [Image #N]
    private static let imageNumPattern = try! NSRegularExpression(
        pattern: "\\[Image #(\\d+)\\]",
        options: []
    )

    /// Parse all messages from a JSONL file for transcript display
    func parseMessages(at path: String) -> [DisplayMessage] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let content = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()

        var messages: [DisplayMessage] = []
        var seenMsgIds: Set<String> = []
        var seenToolIds: Set<String> = []
        var toolResults: [String: String] = [:]      // tool_use_id → result text
        var toolMsgIndices: [String: Int] = [:]       // tool_use_id → index in messages
        var index = 0

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }

            switch entry.type {
            case "queue-operation":
                // Queued user messages (e.g. interrupted and re-sent)
                guard entry.operation == "enqueue" else { continue }
                guard let text = entry.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(DisplayMessage(
                    id: "msg-\(index)", role: "user", text: cleaned, timestamp: entry.timestampDate
                ))
                index += 1

            case "user", "human":
                guard let text = Self.extractAllText(from: entry) else { continue }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }

                if cleaned.hasPrefix("<") && (
                    cleaned.contains("<ide_opened_file>") ||
                    cleaned.contains("<command-message>") ||
                    cleaned.contains("<local-command-caveat>") ||
                    cleaned.contains("<system-reminder>")
                ) { continue }

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

                var msg = DisplayMessage(
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
                            messages[i] = DisplayMessage(
                                id: "text-\(msgId)", role: "assistant", text: text, timestamp: entry.timestampDate
                            )
                        }
                    } else {
                        seenMsgIds.insert(msgId)
                        messages.append(DisplayMessage(
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
                            var msg = DisplayMessage(
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
                messages[msgIdx] = DisplayMessage(
                    id: msg.id, role: msg.role, text: msg.text,
                    timestamp: msg.timestamp, toolName: msg.toolName, toolDetail: result
                )
            }
        }

        return messages
    }

    // MARK: - Tool summary & detail extraction

    /// Returns (summary line, detail content) for a tool call
    private static func toolSummaryAndDetail(name: String, input: AnyCodable?) -> (String, String?) {
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

    /// Extract text from a tool_result content field
    private static func extractToolResultText(_ content: AnyCodable?) -> String? {
        guard let content else { return nil }

        // String result (Read, Bash, Grep, Glob)
        if let str = content.stringValue, !str.isEmpty {
            return str
        }

        // Array result (Agent)
        if let arr = content.value as? [[String: Any]] {
            let texts = arr.compactMap { item -> String? in
                guard (item["type"] as? String) == "text" else { return nil }
                return item["text"] as? String
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }

        return nil
    }

    /// Extract all text content from a message entry (user or assistant)
    static func extractAllText(from entry: TranscriptEntry) -> String? {
        guard let message = entry.message else { return nil }

        if let str = message.contentString {
            return str
        }

        if let content = message.content {
            let texts = content.compactMap { item -> String? in
                if case .text(let tc) = item { return tc.text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }

        return nil
    }

    /// Extract text content from a user message entry
    private static func extractUserText(from entry: TranscriptEntry) -> String? {
        guard let message = entry.message else { return nil }

        // Plain string content (common for user messages)
        if let str = message.contentString {
            return str
        }

        // Array content
        if let content = message.content {
            for item in content {
                if case .text(let tc) = item {
                    return tc.text
                }
            }
        }

        return nil
    }

    /// Clean up user text into a short topic line
    private static func cleanTopic(_ text: String) -> String? {
        // Skip system/IDE messages
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") && (
            trimmed.contains("<ide_opened_file>") ||
            trimmed.contains("<command-message>") ||
            trimmed.contains("<local-command-caveat>") ||
            trimmed.contains("<system-reminder>")
        ) {
            return nil
        }

        // Take the first meaningful line
        let firstLine = trimmed.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? trimmed

        if firstLine.isEmpty { return nil }
        return firstLine
    }
}
