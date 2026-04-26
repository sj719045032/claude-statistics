import Foundation
import ClaudeStatisticsKit

final class CodexTranscriptParser {
    static let shared = CodexTranscriptParser()
    private static let assistantPreviewLimit = 4000

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoFallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private init() {}

    func parseSessionQuick(at path: String) -> SessionQuickStats {
        var quick = SessionQuickStats()
        var userCount = 0
        var assistantCount = 0
        var latestUsage: UsageSnapshot?

        for event in readEvents(at: path) {
            if quick.startTime == nil, let timestamp = event.timestamp {
                quick.startTime = timestamp
            }

            switch event.type {
            case "turn_context":
                if let model = event.payload["model"] as? String, !model.isEmpty {
                    quick.model = model
                }

            case "response_item":
                guard let payloadType = event.payload["type"] as? String else { continue }
                if payloadType == "message" {
                    let role = event.payload["role"] as? String
                    if role == "user", let text = extractMessageText(from: event.payload), let cleaned = cleanUserText(text) {
                        userCount += 1
                        if quick.topic == nil { quick.topic = cleaned }
                        quick.lastPrompt = truncate(cleaned, limit: 200)
                        quick.lastPromptAt = event.timestamp
                    } else if role == "assistant" {
                        assistantCount += 1
                        if let text = extractMessageText(from: event.payload) {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                let truncated = truncate(trimmed, limit: Self.assistantPreviewLimit)
                                if isCodexCommentary(payload: event.payload) {
                                    quick.latestProgressNote = truncated
                                    quick.latestProgressNoteAt = event.timestamp
                                } else {
                                    quick.lastOutputPreview = truncated
                                    quick.lastOutputPreviewAt = event.timestamp
                                }
                            }
                        }
                    }
                } else if payloadType == "function_call" {
                    let rawName = (event.payload["name"] as? String) ?? "tool"
                    let arguments = (event.payload["arguments"] as? String) ?? ""
                    let descriptor = toolDescriptor(name: rawName, arguments: arguments)
                    quick.lastToolName = descriptor.toolName
                    quick.lastToolSummary = toolActivitySummary(for: descriptor)
                    quick.lastToolDetail = descriptor.detail.map { truncate($0, limit: 400) }
                    quick.lastToolAt = event.timestamp
                }

            case "event_msg":
                if isCodexAgentCommentary(payload: event.payload),
                   let text = commentaryText(from: event.payload) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        quick.latestProgressNote = truncate(trimmed, limit: Self.assistantPreviewLimit)
                        quick.latestProgressNoteAt = event.timestamp
                    }
                }
                if let usage = tokenUsage(from: event.payload) {
                    latestUsage = usage.total
                    let lastContext = usage.last.inputTokens + usage.last.cachedInputTokens
                    if lastContext > 0 {
                        quick.totalTokens = usage.total.totalTokens
                    }
                }

            default:
                continue
            }
        }

        quick.userMessageCount = userCount
        quick.messageCount = userCount + assistantCount
        quick.totalTokens = latestUsage?.totalTokens ?? quick.totalTokens
        if let latestUsage, let model = quick.model {
            quick.estimatedCost = ModelPricing.estimateCost(
                model: model,
                inputTokens: latestUsage.inputTokens,
                outputTokens: latestUsage.outputTokens,
                cacheCreation5mTokens: 0,
                cacheCreation1hTokens: 0,
                cacheCreationTotalTokens: 0,
                cacheReadTokens: latestUsage.cachedInputTokens
            )
        }
        if let note = quick.latestProgressNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            DiagnosticLogger.shared.verbose("Codex quick commentary latest session=\((path as NSString).lastPathComponent) len=\(note.count)")
        }
        return quick
    }

    func parseSession(at path: String) -> SessionStats {
        var stats = SessionStats()
        var activeModel = "Unknown"
        var previousTotalUsage: UsageSnapshot?
        var userMessageTimes: [Date] = []
        var toolUseTimes: [(Date, String)] = []

        for event in readEvents(at: path) {
            if let timestamp = event.timestamp {
                if stats.startTime == nil || timestamp < stats.startTime! { stats.startTime = timestamp }
                if stats.endTime == nil || timestamp > stats.endTime! { stats.endTime = timestamp }
            }

            switch event.type {
            case "turn_context":
                if let model = event.payload["model"] as? String, !model.isEmpty {
                    activeModel = model
                    stats.model = model
                }

            case "response_item":
                guard let payloadType = event.payload["type"] as? String else { continue }

                if payloadType == "message" {
                    let role = event.payload["role"] as? String
                    if role == "user", let text = extractMessageText(from: event.payload), let cleaned = cleanUserText(text) {
                        stats.userMessageCount += 1
                        stats.lastPrompt = truncate(cleaned, limit: 200)
                        stats.lastPromptAt = event.timestamp
                        if let timestamp = event.timestamp {
                            userMessageTimes.append(fiveMinuteKey(for: timestamp))
                        }
                    } else if role == "assistant" {
                        stats.assistantMessageCount += 1
                        if let text = extractMessageText(from: event.payload) {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                let truncated = truncate(trimmed, limit: Self.assistantPreviewLimit)
                                if isCodexCommentary(payload: event.payload) {
                                    stats.latestProgressNote = truncated
                                    stats.latestProgressNoteAt = event.timestamp
                                } else {
                                    stats.lastOutputPreview = truncated
                                    stats.lastOutputPreviewAt = event.timestamp
                                }
                            }
                        }
                    }
                } else if payloadType == "function_call",
                          let rawName = event.payload["name"] as? String,
                          let timestamp = event.timestamp {
                    let arguments = (event.payload["arguments"] as? String) ?? ""
                    let descriptor = toolDescriptor(name: rawName, arguments: arguments)
                    stats.lastToolName = descriptor.toolName
                    stats.lastToolSummary = toolActivitySummary(for: descriptor)
                    stats.lastToolDetail = descriptor.detail.map { truncate($0, limit: 400) }
                    stats.lastToolAt = timestamp
                    toolUseTimes.append((fiveMinuteKey(for: timestamp), descriptor.toolName))
                }

            case "event_msg":
                if isCodexAgentCommentary(payload: event.payload),
                   let text = commentaryText(from: event.payload) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        stats.latestProgressNote = truncate(trimmed, limit: Self.assistantPreviewLimit)
                        stats.latestProgressNoteAt = event.timestamp
                    }
                }
                guard let usage = tokenUsage(from: event.payload) else { continue }

                let contextTokens = usage.last.inputTokens + usage.last.cachedInputTokens
                if contextTokens > 0 {
                    stats.contextTokens = contextTokens
                }

                let delta = usage.total.delta(from: previousTotalUsage)
                previousTotalUsage = usage.total

                guard delta.totalTokens > 0, let timestamp = event.timestamp else { continue }

                let sliceKey = fiveMinuteKey(for: timestamp)
                var slice = stats.fiveMinSlices[sliceKey] ?? DaySlice()
                slice.totalInputTokens += delta.inputTokens
                slice.totalOutputTokens += delta.outputTokens
                slice.cacheReadTokens += delta.cachedInputTokens
                slice.messageCount += 1

                var modelStats = slice.modelBreakdown[activeModel, default: ModelTokenStats()]
                modelStats.inputTokens += delta.inputTokens
                modelStats.outputTokens += delta.outputTokens
                modelStats.cacheReadTokens += delta.cachedInputTokens
                modelStats.messageCount += 1
                slice.modelBreakdown[activeModel] = modelStats
                stats.fiveMinSlices[sliceKey] = slice

            default:
                continue
            }
        }

        for time in userMessageTimes {
            stats.fiveMinSlices[time, default: DaySlice()].messageCount += 1
        }

        for (time, toolName) in toolUseTimes {
            stats.fiveMinSlices[time, default: DaySlice()].toolUseCounts[toolName, default: 0] += 1
        }

        if let note = stats.latestProgressNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            DiagnosticLogger.shared.verbose("Codex full commentary latest session=\((path as NSString).lastPathComponent) len=\(note.count)")
        }
        return stats
    }

    func parseMessages(at path: String) -> [TranscriptDisplayMessage] {
        var messages: [TranscriptDisplayMessage] = []
        var toolMessageIndices: [String: Int] = [:]
        var toolResults: [String: String] = [:]

        for event in readEvents(at: path) {
            switch event.type {
            case "response_item":
                guard let payloadType = event.payload["type"] as? String else { continue }

                if payloadType == "message" {
                    let role = event.payload["role"] as? String
                    if role == "user", let text = extractMessageText(from: event.payload), let cleaned = cleanUserText(text) {
                        messages.append(TranscriptDisplayMessage(
                            id: "msg-\(messages.count)",
                            role: "user",
                            text: cleaned,
                            timestamp: event.timestamp
                        ))
                    } else if role == "assistant", let text = extractMessageText(from: event.payload) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        messages.append(TranscriptDisplayMessage(
                            id: "msg-\(messages.count)",
                            role: "assistant",
                            text: trimmed,
                            timestamp: event.timestamp
                        ))
                    }
                } else if payloadType == "function_call" {
                    let callId = (event.payload["call_id"] as? String) ?? UUID().uuidString
                    let rawName = (event.payload["name"] as? String) ?? "tool"
                    let arguments = (event.payload["arguments"] as? String) ?? ""
                    let descriptor = toolDescriptor(name: rawName, arguments: arguments)

                    var message = TranscriptDisplayMessage(
                        id: "tool-\(callId)",
                        role: "tool",
                        text: descriptor.summary,
                        timestamp: event.timestamp,
                        toolName: descriptor.toolName,
                        toolDetail: descriptor.detail
                    )
                    message.editOldString = descriptor.oldString
                    message.editNewString = descriptor.newString
                    toolMessageIndices[callId] = messages.count
                    messages.append(message)
                } else if payloadType == "function_call_output",
                          let callId = event.payload["call_id"] as? String,
                          let output = event.payload["output"] as? String,
                          !output.isEmpty {
                    toolResults[callId] = output
                }

            case "event_msg":
                guard let callId = event.payload["call_id"] as? String else { continue }

                if let aggregated = event.payload["aggregated_output"] as? String, !aggregated.isEmpty {
                    toolResults[callId] = aggregated
                } else if let output = event.payload["output"] as? String, !output.isEmpty {
                    toolResults[callId] = output
                }

            default:
                continue
            }
        }

        for (callId, result) in toolResults {
            guard let index = toolMessageIndices[callId], messages.indices.contains(index) else { continue }
            if let detail = messages[index].toolDetail, !detail.isEmpty {
                messages[index].toolDetail = "\(detail)\n\n\(result)"
            } else {
                messages[index].toolDetail = result
            }
        }

        return messages
    }

    /// Lightweight transcript extraction for FTS indexing. This intentionally
    /// avoids UI transcript assembly and full tool result stitching.
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        var messages: [SearchIndexMessage] = []
        var toolResults: [String: (content: String, timestamp: Date?)] = [:]

        for event in readEvents(at: path) {
            switch event.type {
            case "response_item":
                guard let payloadType = event.payload["type"] as? String else { continue }

                if payloadType == "message" {
                    guard let role = event.payload["role"] as? String,
                          role == "user" || role == "assistant",
                          let text = extractMessageText(from: event.payload),
                          let content = cleanSearchText(text) else { continue }
                    messages.append(SearchIndexMessage(role: role, content: content, timestamp: event.timestamp))
                } else if payloadType == "function_call" {
                    let rawName = (event.payload["name"] as? String) ?? "tool"
                    let arguments = (event.payload["arguments"] as? String) ?? ""
                    guard let content = searchTextForTool(name: rawName, arguments: arguments) else { continue }
                    messages.append(SearchIndexMessage(role: "tool", content: content, timestamp: event.timestamp))
                } else if payloadType == "function_call_output",
                          let callId = event.payload["call_id"] as? String,
                          let output = event.payload["output"] as? String,
                          let content = cleanSearchText(String(output.prefix(500))) {
                    toolResults[callId] = (content, event.timestamp)
                }

            case "event_msg":
                guard let callId = event.payload["call_id"] as? String else { continue }
                let output = (event.payload["aggregated_output"] as? String) ?? (event.payload["output"] as? String)
                guard let output,
                      let content = cleanSearchText(String(output.prefix(500))) else { continue }
                toolResults[callId] = (content, event.timestamp)

            default:
                continue
            }
        }

        for result in toolResults.values {
            messages.append(SearchIndexMessage(role: "tool", content: result.content, timestamp: result.timestamp))
        }

        return messages
    }

    func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]
        var activeModel = "Unknown"
        var previousTotalUsage: UsageSnapshot?

        for event in readEvents(at: filePath) {
            switch event.type {
            case "turn_context":
                if let model = event.payload["model"] as? String, !model.isEmpty {
                    activeModel = model
                }

            case "event_msg":
                guard let usage = tokenUsage(from: event.payload),
                      let timestamp = event.timestamp else {
                    continue
                }

                let delta = usage.total.delta(from: previousTotalUsage)
                previousTotalUsage = usage.total
                guard delta.totalTokens > 0 else { continue }

                let bucket = granularity.bucketStart(for: timestamp)
                var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
                existing.tokens += delta.totalTokens
                existing.cost += ModelPricing.estimateCost(
                    model: activeModel,
                    inputTokens: delta.inputTokens,
                    outputTokens: delta.outputTokens,
                    cacheCreation5mTokens: 0,
                    cacheCreation1hTokens: 0,
                    cacheCreationTotalTokens: 0,
                    cacheReadTokens: delta.cachedInputTokens
                )
                buckets[bucket] = existing

            default:
                continue
            }
        }

        var cumulativeTokens = 0
        var cumulativeCost = 0.0
        return buckets.sorted { $0.key < $1.key }.map { time, bucket in
            cumulativeTokens += bucket.tokens
            cumulativeCost += bucket.cost
            return TrendDataPoint(time: time, tokens: cumulativeTokens, cost: cumulativeCost)
        }
    }

    private func readEvents(at path: String) -> [Event] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let content = String(decoding: data, as: UTF8.self)

        return content
            .components(separatedBy: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let type = json["type"] as? String else {
                    return nil
                }

                let payload = json["payload"] as? [String: Any] ?? [:]
                let timestamp = parseDate(json["timestamp"] as? String)
                return Event(type: type, timestamp: timestamp, payload: payload)
            }
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw) ?? isoFallback.date(from: raw)
    }

    private func extractMessageText(from payload: [String: Any]) -> String? {
        if let content = payload["content"] as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return payload["text"] as? String
    }

    private func commentaryText(from payload: [String: Any]) -> String? {
        if let message = payload["message"] as? String, !message.isEmpty {
            return message
        }
        return extractMessageText(from: payload)
    }

    private func isCodexCommentary(payload: [String: Any]) -> Bool {
        guard (payload["role"] as? String) == "assistant" else { return false }
        return (payload["phase"] as? String) == "commentary"
    }

    private func isCodexAgentCommentary(payload: [String: Any]) -> Bool {
        guard (payload["type"] as? String) == "agent_message" else { return false }
        return (payload["phase"] as? String) == "commentary"
    }

    private func cleanUserText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isInjectedInstructionEnvelope(trimmed) {
            return nil
        }

        let firstLine = trimmed
            .components(separatedBy: .newlines)
            .compactMap(cleanUserTextLine)
            .first

        guard let firstLine, !firstLine.isEmpty else { return nil }
        return firstLine
    }

    private func cleanSearchText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return nil }

        if isInjectedInstructionEnvelope(trimmed) {
            return nil
        }

        let stripped = SearchUtils.stripMarkdown(trimmed)
        return stripped.count > 2 ? stripped : nil
    }

    private func isInjectedInstructionEnvelope(_ text: String) -> Bool {
        text.hasPrefix("<environment_context>")
            || text.hasPrefix("<permissions instructions>")
            || text.hasPrefix("# AGENTS.md instructions for ")
            || text.hasPrefix("<INSTRUCTIONS>")
    }

    private func cleanUserTextLine(_ rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("<image name=")
            || line == "</image>"
            || line == "<environment_context>"
            || line == "</environment_context>"
            || line == "<permissions instructions>"
            || line == "</permissions instructions>"
            || line == "<INSTRUCTIONS>"
            || line == "</INSTRUCTIONS>"
            || line.hasPrefix("# AGENTS.md instructions for ") {
            return nil
        }

        line = line.replacingOccurrences(
            of: #"\[Image #\d+\]"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if line.hasPrefix("# ") {
            line.removeFirst(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return line.isEmpty ? nil : line
    }

    private func searchTextForTool(name rawName: String, arguments: String) -> String? {
        let descriptor = toolDescriptor(name: rawName, arguments: arguments)
        var parts = [descriptor.toolName, descriptor.summary]

        if let detail = descriptor.detail {
            parts.append(String(detail.prefix(2_000)))
        }
        if let oldString = descriptor.oldString {
            parts.append(String(oldString.prefix(1_000)))
        }
        if let newString = descriptor.newString {
            parts.append(String(newString.prefix(1_000)))
        }

        return cleanSearchText(parts.joined(separator: "\n"))
    }

    private func truncate(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private func fiveMinuteKey(for date: Date) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.minute = ((comps.minute ?? 0) / 5) * 5
        return Calendar.current.date(from: comps) ?? date
    }

    private func tokenUsage(from payload: [String: Any]) -> (total: UsageSnapshot, last: UsageSnapshot)? {
        guard (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any],
              let total = UsageSnapshot(json: totalUsage) else {
            return nil
        }

        let lastUsage = (info["last_token_usage"] as? [String: Any]).flatMap(UsageSnapshot.init(json:)) ?? total
        return (total, lastUsage)
    }

    private func normalizedToolName(_ rawName: String) -> String {
        let canonical = ProviderKind.codex.canonicalToolName(rawName)
        let pretty = CanonicalToolName.displayName(for: canonical)
        // `displayName(for:)` title-cases unknown canonicals, which would turn
        // a pass-through name like `view_image` into `View_image`. Keep the
        // provider's raw label when the alias table didn't match.
        return canonical == rawName.lowercased() ? rawName : pretty
    }

    private func toolDescriptor(name rawName: String, arguments: String) -> ToolDescriptor {
        let toolName = normalizedToolName(rawName)
        let payload = parseObjectString(arguments)

        switch rawName {
        case "exec_command":
            let command = (payload?["cmd"] as? String) ?? arguments
            let firstLine = command.components(separatedBy: .newlines).first ?? command
            return ToolDescriptor(toolName: toolName, summary: truncate(firstLine, limit: 140), detail: command)

        case "apply_patch":
            let patch = (payload?["patch"] as? String) ?? arguments
            let summary = firstPatchTarget(in: patch) ?? "Patch"
            return ToolDescriptor(toolName: toolName, summary: summary, detail: patch)

        default:
            if let payload {
                if let cmd = payload["cmd"] as? String {
                    let firstLine = cmd.components(separatedBy: .newlines).first ?? cmd
                    return ToolDescriptor(toolName: toolName, summary: truncate(firstLine, limit: 140), detail: cmd)
                }
                for key in ["path", "filePath", "file_path", "uri", "url", "q", "question", "location"] {
                    if let value = payload[key] as? String, !value.isEmpty {
                        return ToolDescriptor(toolName: toolName, summary: truncate(value, limit: 140), detail: arguments)
                    }
                }
            }

            let fallback = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = fallback.isEmpty ? toolName : truncate(fallback.components(separatedBy: .newlines).first ?? fallback, limit: 140)
            return ToolDescriptor(toolName: toolName, summary: summary, detail: fallback.isEmpty ? nil : fallback)
        }
    }

    private func toolActivitySummary(for descriptor: ToolDescriptor) -> String {
        let summary = descriptor.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.lowercased() != descriptor.toolName.lowercased() else {
            return descriptor.toolName
        }
        return "\(descriptor.toolName) \(summary)"
    }

    private func parseObjectString(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func firstPatchTarget(in patch: String) -> String? {
        for line in patch.components(separatedBy: .newlines) {
            if let path = line.stripPrefix("*** Update File: ") { return path }
            if let path = line.stripPrefix("*** Add File: ") { return path }
            if let path = line.stripPrefix("*** Delete File: ") { return path }
        }
        return nil
    }
}

private struct Event {
    let type: String
    let timestamp: Date?
    let payload: [String: Any]
}

private struct ToolDescriptor {
    let toolName: String
    let summary: String
    let detail: String?
    var oldString: String? = nil
    var newString: String? = nil
}

private struct UsageSnapshot {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let reportedTotalTokens: Int?
    private let rawInputTokens: Int
    private let rawCachedInputTokens: Int
    private let rawOutputTokens: Int
    private let rawReasoningOutputTokens: Int

    var totalTokens: Int {
        reportedTotalTokens ?? (inputTokens + cachedInputTokens + outputTokens)
    }

    init?(json: [String: Any]) {
        self.init(
            rawInputTokens: json["input_tokens"] as? Int ?? 0,
            rawCachedInputTokens: json["cached_input_tokens"] as? Int ?? 0,
            rawOutputTokens: json["output_tokens"] as? Int ?? 0,
            rawReasoningOutputTokens: json["reasoning_output_tokens"] as? Int ?? 0,
            reportedTotalTokens: json["total_tokens"] as? Int
        )
    }

    private init(rawInputTokens: Int, rawCachedInputTokens: Int, rawOutputTokens: Int, rawReasoningOutputTokens: Int, reportedTotalTokens rawReportedTotalTokens: Int?) {
        let inputIncludesCached: Bool
        let outputIncludesReasoning: Bool
        if let rawReportedTotalTokens {
            inputIncludesCached =
                rawReportedTotalTokens == rawInputTokens + rawOutputTokens ||
                rawReportedTotalTokens == rawInputTokens + rawOutputTokens + rawReasoningOutputTokens
            outputIncludesReasoning =
                rawReportedTotalTokens == rawInputTokens + rawOutputTokens ||
                rawReportedTotalTokens == rawInputTokens + rawCachedInputTokens + rawOutputTokens
        } else {
            inputIncludesCached = true
            outputIncludesReasoning = true
        }

        inputTokens = inputIncludesCached ? max(0, rawInputTokens - rawCachedInputTokens) : rawInputTokens
        cachedInputTokens = rawCachedInputTokens
        outputTokens = outputIncludesReasoning ? rawOutputTokens : rawOutputTokens + rawReasoningOutputTokens
        reasoningOutputTokens = outputIncludesReasoning ? rawReasoningOutputTokens : 0
        reportedTotalTokens = rawReportedTotalTokens
        self.rawInputTokens = rawInputTokens
        self.rawCachedInputTokens = rawCachedInputTokens
        self.rawOutputTokens = rawOutputTokens
        self.rawReasoningOutputTokens = rawReasoningOutputTokens
    }

    func delta(from previous: UsageSnapshot?) -> UsageSnapshot {
        guard let previous else { return self }
        return UsageSnapshot(
            rawInputTokens: max(0, rawInputTokens - previous.rawInputTokens),
            rawCachedInputTokens: max(0, rawCachedInputTokens - previous.rawCachedInputTokens),
            rawOutputTokens: max(0, rawOutputTokens - previous.rawOutputTokens),
            rawReasoningOutputTokens: max(0, rawReasoningOutputTokens - previous.rawReasoningOutputTokens),
            reportedTotalTokens: reportedTotalTokens.flatMap { total in
                previous.reportedTotalTokens.map { max(0, total - $0) } ?? total
            }
        )
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
