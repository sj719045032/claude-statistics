import Foundation

final class TranscriptParser {
    static let shared = TranscriptParser()

    private init() {}

    /// Per-message accumulated data (streaming produces multiple entries; we keep the last/final one)
    private struct MessageAccum {
        var model: String
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheCreationTotalTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreation5mTokens: Int = 0
        var cacheCreation1hTokens: Int = 0
    }

    func parseSession(at path: String) -> SessionStats {
        var stats = SessionStats()

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return stats
        }

        let decoder = JSONDecoder()
        let lines = content.components(separatedBy: "\n")
        // Store per-message data; last entry wins (streaming sends partial then final usage)
        var messageData: [String: MessageAccum] = [:]
        var seenToolUseIds: Set<String> = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }

            guard let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }

            // Track timestamps
            if let date = entry.timestampDate {
                if stats.startTime == nil || date < stats.startTime! {
                    stats.startTime = date
                }
                if stats.endTime == nil || date > stats.endTime! {
                    stats.endTime = date
                }
            }

            switch entry.type {
            case "user", "human":
                stats.userMessageCount += 1
                stats.messageCount += 1
                // Track last user text for "Last Prompt"
                if let text = Self.extractUserText(from: entry) {
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        stats.lastPrompt = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
                    }
                }

            case "assistant":
                if let message = entry.message {
                    let msgId = message.id ?? UUID().uuidString
                    let isFirstOccurrence = messageData[msgId] == nil

                    if isFirstOccurrence {
                        stats.assistantMessageCount += 1
                        stats.messageCount += 1
                    }

                    // Track model (skip synthetic messages)
                    let isSynthetic = message.model == "<synthetic>"
                    let currentModel = isSynthetic ? stats.model : (message.model ?? stats.model)
                    if let model = message.model, model != "Unknown", !isSynthetic {
                        stats.model = model
                    }

                    // Always update context tokens from latest entry
                    if let usage = message.usage {
                        let input = usage.inputTokens ?? 0
                        let cacheTotal = usage.cacheCreationInputTokens ?? 0
                        let cacheRead = usage.cacheReadInputTokens ?? 0
                        let contextSize = input + cacheTotal + cacheRead
                        if contextSize > 0 {
                            stats.contextTokens = contextSize
                        }
                    }

                    // Overwrite per-message usage with latest entry (last entry has final output tokens)
                    if let usage = message.usage {
                        messageData[msgId] = MessageAccum(
                            model: currentModel,
                            inputTokens: usage.inputTokens ?? 0,
                            outputTokens: usage.outputTokens ?? 0,
                            cacheCreationTotalTokens: usage.cacheCreationInputTokens ?? 0,
                            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                            cacheCreation5mTokens: usage.cacheCreation?.ephemeral5mInputTokens ?? 0,
                            cacheCreation1hTokens: usage.cacheCreation?.ephemeral1hInputTokens ?? 0
                        )
                    }

                    // Track tool uses (deduplicate by tool_use_id if available)
                    if let content = message.content {
                        for item in content {
                            if let toolName = item.toolUseName {
                                let toolId = item.toolUseId ?? UUID().uuidString
                                if !seenToolUseIds.contains(toolId) {
                                    seenToolUseIds.insert(toolId)
                                    stats.toolUseCounts[toolName, default: 0] += 1
                                }
                            }
                        }
                    }
                }

            default:
                break
            }
        }

        // Sum final per-message usage data
        for (_, accum) in messageData {
            stats.totalInputTokens += accum.inputTokens
            stats.totalOutputTokens += accum.outputTokens
            stats.cacheCreationTotalTokens += accum.cacheCreationTotalTokens
            stats.cacheReadTokens += accum.cacheReadTokens
            stats.cacheCreation5mTokens += accum.cacheCreation5mTokens
            stats.cacheCreation1hTokens += accum.cacheCreation1hTokens

            // Per-model breakdown
            var ms = stats.modelBreakdown[accum.model, default: ModelTokenStats()]
            ms.inputTokens += accum.inputTokens
            ms.outputTokens += accum.outputTokens
            ms.cacheCreationTotalTokens += accum.cacheCreationTotalTokens
            ms.cacheReadTokens += accum.cacheReadTokens
            ms.cacheCreation5mTokens += accum.cacheCreation5mTokens
            ms.cacheCreation1hTokens += accum.cacheCreation1hTokens
            ms.messageCount += 1
            stats.modelBreakdown[accum.model] = ms
        }

        return stats
    }

    /// Parse JSONL into time-bucketed trend data points for chart display
    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

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
            guard let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }
            guard entry.type == "assistant",
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
    struct QuickStats {
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
        guard let content = String(data: data, encoding: .utf8) else {
            return quick
        }

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
        if let tailContent = String(data: tailData, encoding: .utf8) {
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
        }

        return quick
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
