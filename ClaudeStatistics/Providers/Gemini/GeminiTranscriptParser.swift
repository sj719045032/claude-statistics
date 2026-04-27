import Foundation
import ClaudeStatisticsKit

final class GeminiTranscriptParser {
    static let shared = GeminiTranscriptParser()
    private static let assistantPreviewLimit = 4000

    private init() {}

    func loadSession(at path: String) -> GeminiChatSession? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let messages = (json["messages"] as? [[String: Any]] ?? []).compactMap(parseMessage)
        let fileSessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        return GeminiChatSession(
            sessionId: json["sessionId"] as? String ?? fileSessionId,
            projectHash: json["projectHash"] as? String,
            startTime: parseDate(json["startTime"] as? String),
            lastUpdated: parseDate(json["lastUpdated"] as? String),
            summary: normalizedText(json["summary"]),
            messages: messages
        )
    }

    func parseSessionQuick(at path: String) -> SessionQuickStats {
        guard let session = loadSession(at: path) else { return SessionQuickStats() }

        var quick = SessionQuickStats()
        quick.startTime = session.startTime ?? session.messages.compactMap(\.timestamp).min()
        quick.sessionName = TitleSanitizer.sanitize(session.summary)

        var latestModel: String?
        var userCount = 0
        var assistantCount = 0

        for message in session.messages {
            switch message.type {
            case "user":
                guard let cleaned = cleanUserText(message.text) else { continue }
                userCount += 1
                if quick.topic == nil { quick.topic = cleaned }
                quick.lastPrompt = truncate(cleaned, limit: 200)
                quick.lastPromptAt = message.timestamp

            case "gemini":
                assistantCount += 1
                if let model = normalizedText(message.model) {
                    latestModel = model
                    quick.model = model
                }
                if let text = normalizedText(message.text) {
                    quick.lastOutputPreview = truncate(text, limit: Self.assistantPreviewLimit)
                    quick.lastOutputPreviewAt = message.timestamp
                } else if let toolCall = message.toolCalls.last {
                    quick.lastOutputPreview = truncate(toolSummary(for: toolCall), limit: Self.assistantPreviewLimit)
                    quick.lastOutputPreviewAt = message.timestamp
                }
                if let tokens = message.tokens {
                    quick.totalTokens += tokens.totalTokens
                    if let model = normalizedText(message.model) ?? latestModel {
                        quick.estimatedCost += estimatedCost(for: tokens, model: model)
                    }
                }
                if let toolCall = message.toolCalls.last {
                    quick.lastToolName = normalizedToolName(toolCall)
                    quick.lastToolSummary = toolActivitySummary(for: toolCall)
                    quick.lastToolDetail = toolDetail(for: toolCall).map { truncate($0, limit: 400) }
                    quick.lastToolAt = message.timestamp
                }

            default:
                continue
            }
        }

        quick.userMessageCount = userCount
        quick.messageCount = userCount + assistantCount
        if quick.model == nil {
            quick.model = latestModel
        }
        return quick
    }

    func parseSession(at path: String) -> SessionStats {
        guard let session = loadSession(at: path) else { return SessionStats() }

        var stats = SessionStats()
        stats.startTime = session.startTime
        stats.endTime = session.lastUpdated
        var activeModel = "Unknown"

        for message in session.messages {
            if let timestamp = message.timestamp {
                if stats.startTime == nil || timestamp < stats.startTime! { stats.startTime = timestamp }
                if stats.endTime == nil || timestamp > stats.endTime! { stats.endTime = timestamp }
            }

            switch message.type {
            case "user":
                guard let cleaned = cleanUserText(message.text) else { continue }
                stats.userMessageCount += 1
                stats.lastPrompt = truncate(cleaned, limit: 200)
                stats.lastPromptAt = message.timestamp
                if let timestamp = message.timestamp {
                    stats.fiveMinSlices[fiveMinuteKey(for: timestamp), default: DaySlice()].messageCount += 1
                }

            case "gemini":
                stats.assistantMessageCount += 1
                if let model = normalizedText(message.model) {
                    activeModel = model
                    stats.model = model
                }
                if let text = normalizedText(message.text) {
                    stats.lastOutputPreview = truncate(text, limit: Self.assistantPreviewLimit)
                    stats.lastOutputPreviewAt = message.timestamp
                } else if let toolCall = message.toolCalls.last {
                    stats.lastOutputPreview = truncate(toolSummary(for: toolCall), limit: Self.assistantPreviewLimit)
                    stats.lastOutputPreviewAt = message.timestamp
                }

                let sliceKey = message.timestamp.map(fiveMinuteKey(for:))
                if let tokens = message.tokens, let sliceKey {
                    let outputTokens = tokens.billedOutputTokens
                    let contextTokens = tokens.inputTokens + tokens.cachedTokens
                    if contextTokens > 0 {
                        stats.contextTokens = contextTokens
                    }

                    var slice = stats.fiveMinSlices[sliceKey] ?? DaySlice()
                    slice.totalInputTokens += tokens.inputTokens
                    slice.totalOutputTokens += outputTokens
                    slice.cacheReadTokens += tokens.cachedTokens
                    slice.messageCount += 1

                    var modelStats = slice.modelBreakdown[activeModel, default: ModelTokenStats()]
                    modelStats.inputTokens += tokens.inputTokens
                    modelStats.outputTokens += outputTokens
                    modelStats.cacheReadTokens += tokens.cachedTokens
                    modelStats.messageCount += 1
                    slice.modelBreakdown[activeModel] = modelStats
                    stats.fiveMinSlices[sliceKey] = slice
                } else if let sliceKey {
                    stats.fiveMinSlices[sliceKey, default: DaySlice()].messageCount += 1
                }

                if let sliceKey {
                    for toolCall in message.toolCalls {
                        let toolName = normalizedToolName(toolCall)
                        stats.fiveMinSlices[sliceKey, default: DaySlice()].toolUseCounts[toolName, default: 0] += 1
                    }
                }
                if let toolCall = message.toolCalls.last {
                    stats.lastToolName = normalizedToolName(toolCall)
                    stats.lastToolSummary = toolActivitySummary(for: toolCall)
                    stats.lastToolDetail = toolDetail(for: toolCall).map { truncate($0, limit: 400) }
                    stats.lastToolAt = message.timestamp
                }

            default:
                continue
            }
        }

        stats.precomputeAggregates()
        return stats
    }

    func parseMessages(at path: String) -> [TranscriptDisplayMessage] {
        guard let session = loadSession(at: path) else { return [] }

        var messages: [TranscriptDisplayMessage] = []

        for message in session.messages {
            switch message.type {
            case "user":
                guard let cleaned = cleanUserText(message.text) else { continue }
                messages.append(TranscriptDisplayMessage(
                    id: message.id,
                    role: "user",
                    text: cleaned,
                    timestamp: message.timestamp
                ))

            case "gemini":
                if let text = normalizedText(message.text) {
                    messages.append(TranscriptDisplayMessage(
                        id: message.id,
                        role: "assistant",
                        text: text,
                        timestamp: message.timestamp
                    ))
                }

                for toolCall in message.toolCalls {
                    var toolMessage = TranscriptDisplayMessage(
                        id: "tool-\(toolCall.id)",
                        role: "tool",
                        text: toolSummary(for: toolCall),
                        timestamp: message.timestamp,
                        toolName: normalizedToolName(toolCall),
                        toolDetail: toolDetail(for: toolCall)
                    )

                    if let args = toolCall.args as? [String: Any] {
                        toolMessage.editOldString = args["old_string"] as? String
                        toolMessage.editNewString = args["new_string"] as? String
                    }

                    messages.append(toolMessage)
                }

            case "info":
                if let text = normalizedText(message.text) {
                    messages.append(TranscriptDisplayMessage(
                        id: message.id,
                        role: "assistant",
                        text: "[Info] \(text)",
                        timestamp: message.timestamp
                    ))
                }

            case "error":
                if let text = normalizedText(message.text) {
                    messages.append(TranscriptDisplayMessage(
                        id: message.id,
                        role: "assistant",
                        text: "[Error] \(text)",
                        timestamp: message.timestamp
                    ))
                }

            default:
                continue
            }
        }

        return messages
    }

    /// Lightweight transcript extraction for FTS indexing. Gemini chats are JSON
    /// documents, but this avoids constructing UI messages and full display state.
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        guard let session = loadSession(at: path) else { return [] }

        var messages: [SearchIndexMessage] = []

        for message in session.messages {
            switch message.type {
            case "user":
                guard let content = cleanSearchText(message.text) else { continue }
                messages.append(SearchIndexMessage(role: "user", content: content, timestamp: message.timestamp))

            case "gemini":
                if let content = cleanSearchText(message.text) {
                    messages.append(SearchIndexMessage(role: "assistant", content: content, timestamp: message.timestamp))
                }

                for toolCall in message.toolCalls {
                    guard let content = searchText(for: toolCall) else { continue }
                    messages.append(SearchIndexMessage(role: "tool", content: content, timestamp: message.timestamp))
                }

            case "info":
                guard let content = cleanSearchText(message.text) else { continue }
                messages.append(SearchIndexMessage(role: "assistant", content: "[Info] \(content)", timestamp: message.timestamp))

            case "error":
                guard let content = cleanSearchText(message.text) else { continue }
                messages.append(SearchIndexMessage(role: "assistant", content: "[Error] \(content)", timestamp: message.timestamp))

            default:
                continue
            }
        }

        return messages
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        guard let session = loadSession(at: filePath) else { return [] }

        var buckets: [Date: (tokens: Int, cost: Double)] = [:]

        for message in session.messages where message.type == "gemini" {
            guard let timestamp = message.timestamp,
                  let tokens = message.tokens else {
                continue
            }

            let bucket = granularity.bucketStart(for: timestamp)
            var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
            existing.tokens += tokens.totalTokens
            if let model = normalizedText(message.model) {
                existing.cost += estimatedCost(for: tokens, model: model)
            }
            buckets[bucket] = existing
        }

        var cumulativeTokens = 0
        var cumulativeCost = 0.0
        return buckets.sorted { $0.key < $1.key }.map { time, bucket in
            cumulativeTokens += bucket.tokens
            cumulativeCost += bucket.cost
            return TrendDataPoint(time: time, tokens: cumulativeTokens, cost: cumulativeCost)
        }
    }

    private func parseMessage(_ json: [String: Any]) -> GeminiChatMessage? {
        guard let type = json["type"] as? String else { return nil }

        let toolCalls = (json["toolCalls"] as? [[String: Any]] ?? []).map { tool in
            GeminiToolCall(
                id: normalizedText(tool["id"]) ?? UUID().uuidString,
                name: normalizedText(tool["name"]) ?? "tool",
                displayName: normalizedText(tool["displayName"]),
                args: tool["args"],
                rawResult: tool["result"],
                resultDisplay: normalizedText(tool["resultDisplay"]),
                description: normalizedText(tool["description"])
            )
        }

        return GeminiChatMessage(
            id: normalizedText(json["id"]) ?? UUID().uuidString,
            timestamp: parseDate(json["timestamp"] as? String),
            type: type,
            text: extractText(from: json["content"]),
            tokens: parseTokens(json["tokens"] as? [String: Any]),
            model: normalizedText(json["model"]),
            toolCalls: toolCalls
        )
    }

    private func parseTokens(_ json: [String: Any]?) -> GeminiTokenUsage? {
        guard let json else { return nil }
        
        let rawInput = intValue(json["input"] ?? json["input_tokens"] ?? json["prompt_tokens"])
        let output = intValue(json["output"] ?? json["output_tokens"] ?? json["completion_tokens"])
        let cached = intValue(json["cached"] ?? json["cached_tokens"] ?? json["cache_read_tokens"])
        let thoughts = intValue(json["thoughts"] ?? json["thought_tokens"])
        let tool = intValue(json["tool"] ?? json["tool_tokens"])
        let total = intValue(json["total"] ?? json["total_tokens"])
        
        // If we have total but missing breakdown, try to infer or at least return the total
        if total > 0 && rawInput == 0 && output == 0 {
            return GeminiTokenUsage(
                inputTokens: total, // Fallback: treat total as input if no breakdown
                outputTokens: 0,
                cachedTokens: 0,
                thoughtTokens: 0,
                toolTokens: 0,
                rawTotalTokens: total
            )
        }

        let billedOutput = output + thoughts + tool
        let inputIncludesCached = total > 0
            ? total == rawInput + billedOutput
            : true
        
        return GeminiTokenUsage(
            inputTokens: inputIncludesCached ? max(0, rawInput - cached) : rawInput,
            outputTokens: output,
            cachedTokens: cached,
            thoughtTokens: thoughts,
            toolTokens: tool,
            rawTotalTokens: total
        )
    }

    private func parseDate(_ raw: String?) -> Date? {
        TranscriptParserCommons.parseISOTimestamp(raw)
    }

    private func extractText(from raw: Any?) -> String? {
        if let text = raw as? String {
            return normalizedText(text)
        }

        if let content = raw as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                return nil
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }

        return nil
    }

    private func normalizedText(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func intValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return 0
    }

    private func cleanUserText(_ text: String?) -> String? {
        TitleSanitizer.sanitize(text)
    }

    private func cleanSearchText(_ text: String?) -> String? {
        guard let text else { return nil }
        return TranscriptParserCommons.searchTextClean(text)
    }

    private func searchText(for toolCall: GeminiToolCall) -> String? {
        var parts = [normalizedToolName(toolCall), toolSummary(for: toolCall)]

        if let args = toolCall.args as? [String: Any] {
            for key in ["cmd", "command", "pattern", "file_path", "path", "url", "query", "old_string", "new_string"] {
                if let value = normalizedText(args[key]) {
                    parts.append(String(value.prefix(1_000)))
                }
            }
        } else if let args = normalizedText(toolCall.args) {
            parts.append(String(args.prefix(1_000)))
        }

        if let resultDisplay = toolCall.resultDisplay {
            parts.append(String(resultDisplay.prefix(500)))
        }
        if let output = extractedToolOutput(from: toolCall.rawResult) {
            parts.append(String(output.prefix(500)))
        }
        if let description = toolCall.description {
            parts.append(String(description.prefix(500)))
        }

        return cleanSearchText(parts.joined(separator: "\n"))
    }

    private func truncate(_ text: String, limit: Int) -> String {
        TranscriptParserCommons.truncate(text, limit: limit)
    }

    private func fiveMinuteKey(for date: Date) -> Date {
        TranscriptParserCommons.fiveMinuteSliceKey(for: date)
    }

    private func estimatedCost(for tokens: GeminiTokenUsage, model: String) -> Double {
        ModelPricing.estimateCost(
            model: model,
            inputTokens: tokens.inputTokens,
            outputTokens: tokens.billedOutputTokens,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            cacheCreationTotalTokens: 0,
            cacheReadTokens: tokens.cachedTokens
        )
    }

    private func normalizedToolName(_ toolCall: GeminiToolCall) -> String {
        let canonical = ProviderKind.gemini.descriptor.canonicalToolName(toolCall.name)
        // Keep Gemini's own displayName when the alias table didn't match —
        // `displayName(for:)` would otherwise title-case an unknown key.
        if canonical.isEmpty || canonical == toolCall.name.lowercased() {
            return toolCall.displayName ?? toolCall.name
        }
        return canonical
    }

    private func toolSummary(for toolCall: GeminiToolCall) -> String {
        if let args = toolCall.args as? [String: Any] {
            for key in ["cmd", "command", "pattern", "file_path", "path", "url", "query"] {
                if let value = normalizedText(args[key]) {
                    let firstLine = value.components(separatedBy: .newlines).first ?? value
                    return truncate(firstLine, limit: 140)
                }
            }
        }

        if let resultDisplay = toolCall.resultDisplay {
            return truncate(resultDisplay, limit: 140)
        }

        if let output = extractedToolOutput(from: toolCall.rawResult) {
            let firstLine = output.components(separatedBy: .newlines).first ?? output
            return truncate(firstLine, limit: 140)
        }

        if let description = toolCall.description {
            return truncate(description, limit: 140)
        }

        return normalizedToolName(toolCall)
    }

    private func toolActivitySummary(for toolCall: GeminiToolCall) -> String {
        let toolName = normalizedToolName(toolCall)

        if let args = toolCall.args as? [String: Any] {
            switch toolName.lowercased() {
            case "bash":
                if let command = normalizedText(args["command"] ?? args["cmd"]) {
                    return truncate("Running: \(command)", limit: 140)
                }
                return "Running command…"

            case "read", "readfile":
                if let path = normalizedText(args["file_path"] ?? args["path"] ?? args["filePath"]) {
                    return truncate("Reading \(lastPathComponent(path))…", limit: 140)
                }
                return "Reading…"

            case "write":
                if let path = normalizedText(args["file_path"] ?? args["path"] ?? args["filePath"]) {
                    return truncate("Writing \(lastPathComponent(path))…", limit: 140)
                }
                return "Writing…"

            case "edit", "replace":
                if let path = normalizedText(args["file_path"] ?? args["path"] ?? args["filePath"]) {
                    return truncate("Editing \(lastPathComponent(path))…", limit: 140)
                }
                return "Editing…"

            case "grep":
                if let pattern = normalizedText(args["pattern"]) {
                    return truncate("Searching: \(pattern)", limit: 140)
                }
                return "Searching…"

            case "glob", "findfiles":
                if let path = normalizedText(args["path"] ?? args["file_path"] ?? args["filePath"]) {
                    return truncate("Finding files in \(lastPathComponent(path))…", limit: 140)
                }
                return "Finding files…"

            case "fetch", "webfetch":
                if let url = normalizedText(args["url"]) {
                    return truncate("Fetching: \(url)", limit: 140)
                }
                return "Fetching…"

            case "websearch":
                if let query = normalizedText(args["query"] ?? args["q"] ?? args["prompt"]) {
                    return truncate("Searching: \(query)", limit: 140)
                }
                return "Searching the web…"

            default:
                break
            }
        }

        if let summary = normalizedText(toolCall.description) {
            return truncate(summary, limit: 140)
        }

        let fallback = toolSummary(for: toolCall)
        if fallback.caseInsensitiveCompare(toolName) != .orderedSame {
            return fallback
        }
        return toolName
    }

    private func toolDetail(for toolCall: GeminiToolCall) -> String? {
        var parts: [String] = []

        if let args = jsonString(from: toolCall.args) {
            parts.append(args)
        }

        if let output = extractedToolOutput(from: toolCall.rawResult) {
            parts.append(output)
        } else if let result = jsonString(from: toolCall.rawResult) {
            parts.append(result)
        }

        let detail = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return detail.isEmpty ? nil : detail
    }

    private func extractedToolOutput(from raw: Any?) -> String? {
        if let text = normalizedText(raw) {
            return sanitizedToolOutput(text)
        }

        if let array = raw as? [Any] {
            for item in array {
                if let output = extractedToolOutput(from: item) {
                    return output
                }
            }
            return nil
        }

        guard let dict = raw as? [String: Any] else { return nil }

        for key in ["output", "resultDisplay", "description"] {
            if let text = normalizedText(dict[key]) {
                return sanitizedToolOutput(text)
            }
        }

        for key in ["functionResponse", "response"] {
            if let nested = extractedToolOutput(from: dict[key]) {
                return nested
            }
        }

        return nil
    }

    private func sanitizedToolOutput(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ToolOutputCleaning.cleanedLine(String($0)) }
            .filter { !$0.isEmpty && !ToolOutputCleaning.isUnhelpfulMetadataLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    private func lastPathComponent(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? path : last
    }

    private func jsonString(from raw: Any?) -> String? {
        guard let raw else { return nil }
        if let text = raw as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GeminiChatSession {
    let sessionId: String
    let projectHash: String?
    let startTime: Date?
    let lastUpdated: Date?
    let summary: String?
    let messages: [GeminiChatMessage]
}

struct GeminiChatMessage {
    let id: String
    let timestamp: Date?
    let type: String
    let text: String?
    let tokens: GeminiTokenUsage?
    let model: String?
    let toolCalls: [GeminiToolCall]
}

struct GeminiToolCall {
    let id: String
    let name: String
    let displayName: String?
    let args: Any?
    let rawResult: Any?
    let resultDisplay: String?
    let description: String?
}

struct GeminiTokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let thoughtTokens: Int
    let toolTokens: Int
    let rawTotalTokens: Int

    var billedOutputTokens: Int {
        outputTokens + thoughtTokens + toolTokens
    }

    var totalTokens: Int {
        inputTokens + cachedTokens + billedOutputTokens
    }
}
