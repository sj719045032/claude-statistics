import Foundation
import ClaudeStatisticsKit

extension TranscriptParser {
    /// Parse only basic info (fast, reads first few lines)
    func parseSessionQuick(at path: String) -> SessionQuickStats {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return SessionQuickStats()
        }
        defer { handle.closeFile() }

        var quick = SessionQuickStats()
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
            var foundOutputPreview = false
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
                        if let cleaned = Self.cleanUserDisplayText(text) {
                            quick.lastPrompt = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
                            quick.lastPromptAt = entry.timestampDate
                            foundPrompt = true
                        }
                    }
                }

                if !foundOutputPreview, entry.type == "assistant",
                   let message = entry.message,
                   let preview = Self.extractAssistantPreview(from: message) {
                    quick.lastOutputPreview = preview
                    quick.lastOutputPreviewAt = entry.timestampDate
                    // Mirror the preview into latestProgressNote so the
                    // triptych's BOTTOM row (agent commentary) has a second
                    // data source. The hook's tail-read is the fast path; this
                    // parser scan is the safety net when the hook misses.
                    quick.latestProgressNote = preview
                    quick.latestProgressNoteAt = entry.timestampDate
                    foundOutputPreview = true
                }
            }
            quick.sessionName = TitleSanitizer.sanitize(latestCustomTitle ?? latestSlug)
        }  // end do

        // If the initial 16 KB read didn't surface a topic (e.g. the first real user
        // message was embedded in a large line containing base64 image data), do a
        // dedicated line-by-line scan that handles oversized lines.
        if quick.topic == nil {
            quick.topic = Self.findTopicByLineScan(at: path)
        }

        return quick
    }

    /// Extract text content from a user message entry
    static func extractUserText(from entry: TranscriptEntry) -> String? {
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

    // MARK: - Large-line topic extraction

    /// Read one newline-delimited line from `handle`, using `buffer` for lookahead.
    fileprivate static func readLineData(from handle: FileHandle, buffer: inout Data) -> Data? {
        let newline = UInt8(ascii: "\n")
        while true {
            if let nlIdx = buffer.firstIndex(of: newline) {
                let line = Data(buffer[..<nlIdx])
                buffer = Data(buffer[(buffer.index(after: nlIdx)...)])
                if !line.isEmpty { return line }
                continue  // skip empty lines
            }
            let chunk = handle.readData(ofLength: 16384)
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                let remaining = buffer
                buffer = Data()
                return remaining
            }
            buffer.append(contentsOf: chunk)
        }
    }

    /// For lines too large to decode as JSON (e.g. containing base64 image data),
    /// try to pull the first text field from the leading bytes of the line.
    fileprivate static func extractTextFromLargeUserLine(_ data: Data) -> String? {
        let headerBytes = data.prefix(512)
        let header = String(decoding: headerBytes, as: UTF8.self)
        guard header.contains("\"type\":\"user\"") || header.contains("\"type\":\"human\"") else { return nil }

        let searchStr = String(decoding: data.prefix(8192), as: UTF8.self)
        let marker = "\"type\":\"text\",\"text\":\""
        guard let markerRange = searchStr.range(of: marker) else { return nil }

        var result = ""
        var idx = markerRange.upperBound
        var escaped = false
        while idx < searchStr.endIndex, result.count < 500 {
            let c = searchStr[idx]
            if escaped {
                escaped = false
                if c != "u" { result.append(c) }
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                result.append(c)
            }
            idx = searchStr.index(after: idx)
        }
        return result.isEmpty ? nil : result
    }

    /// Secondary topic scan used when the initial 16 KB read didn't find a topic.
    /// Reads the file line-by-line (up to 100 lines) and handles large lines
    /// (e.g. user messages with embedded base64 images) via regex extraction.
    fileprivate static func findTopicByLineScan(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let decoder = JSONDecoder()
        var buffer = Data()
        var lineCount = 0

        while lineCount < 100 {
            guard let lineData = readLineData(from: handle, buffer: &buffer) else { break }
            lineCount += 1

            if lineData.count > 65536 {
                if let text = extractTextFromLargeUserLine(lineData),
                   let topic = cleanTopic(text) {
                    return topic
                }
                continue
            }

            guard let entry = try? decoder.decode(TranscriptEntry.self, from: lineData),
                  entry.type == "user" || entry.type == "human",
                  let text = extractUserText(from: entry),
                  let topic = cleanTopic(text) else { continue }
            return topic
        }
        return nil
    }
}
