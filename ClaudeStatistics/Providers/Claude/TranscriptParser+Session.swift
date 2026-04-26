import Foundation
import ClaudeStatisticsKit

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

extension TranscriptParser {
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
                    if let text,
                       let cleaned = Self.cleanUserDisplayText(text) {
                        stats.lastPrompt = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
                        stats.lastPromptAt = timestamp
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

                if let preview = Self.extractAssistantPreview(fromRawMessage: message) {
                    stats.lastOutputPreview = preview
                    stats.lastOutputPreviewAt = timestamp
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
                var slice = stats.fiveMinSlices[sliceKey] ?? DaySlice()
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
            stats.fiveMinSlices[time, default: DaySlice()].messageCount += 1
        }
        for (time, toolName) in toolUseTimes {
            stats.fiveMinSlices[time, default: DaySlice()].toolUseCounts[toolName, default: 0] += 1
            stats.fiveMinSlices[time, default: DaySlice()].messageCount += 1
        }

        stats.precomputeAggregates()

        DiagnosticLogger.shared.parsingSummary(
            file: path,
            totalLines: messageData.count + stats.userMessageCount,
            skippedLines: 0,
            messages: stats.messageCount,
            tokens: stats.totalTokens
        )

        return stats
    }
}
