import Foundation

final class TranscriptParser {
    static let shared = TranscriptParser()

    private init() {}

    func parseSession(at path: String) -> SessionStats {
        var stats = SessionStats()

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return stats
        }

        let decoder = JSONDecoder()
        let lines = content.components(separatedBy: "\n")

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
            case "user":
                stats.userMessageCount += 1
                stats.messageCount += 1

            case "assistant":
                stats.assistantMessageCount += 1
                stats.messageCount += 1

                if let message = entry.message {
                    // Track model
                    if let model = message.model, model != "Unknown" {
                        stats.model = model
                    }

                    // Track tokens
                    if let usage = message.usage {
                        stats.totalInputTokens += usage.inputTokens ?? 0
                        stats.totalOutputTokens += usage.outputTokens ?? 0
                        stats.cacheCreationTotalTokens += usage.cacheCreationInputTokens ?? 0
                        stats.cacheReadTokens += usage.cacheReadInputTokens ?? 0

                        // Track 5m/1h cache breakdown if available
                        if let detail = usage.cacheCreation {
                            stats.cacheCreation5mTokens += detail.ephemeral5mInputTokens ?? 0
                            stats.cacheCreation1hTokens += detail.ephemeral1hInputTokens ?? 0
                        }
                    }

                    // Track tool uses
                    if let content = message.content {
                        for item in content {
                            if let toolName = item.toolUseName {
                                stats.toolUseCounts[toolName, default: 0] += 1
                            }
                        }
                    }
                }

            case "last-prompt":
                stats.lastPrompt = entry.lastPrompt

            default:
                break
            }
        }

        return stats
    }

    /// Parse only basic info (fast, reads first few lines)
    struct QuickStats {
        var startTime: Date?
        var model: String?
        var topic: String?
        var lastPrompt: String?
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
                if quick.model == nil, let m = entry.message?.model {
                    quick.model = m
                }
                quick.messageCount += 1
                if let usage = entry.message?.usage {
                    totalInput += usage.inputTokens ?? 0
                    totalOutput += usage.outputTokens ?? 0
                    cacheCreate += usage.cacheCreationInputTokens ?? 0
                    cacheRead += usage.cacheReadInputTokens ?? 0
                }
            } else if entry.type == "human" {
                quick.messageCount += 1
                quick.userMessageCount += 1
            }
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

        // Read last prompt from end of file
        if fileSize > 2048 {
            handle.seek(toFileOffset: fileSize - 2048)
            let tailData = handle.readData(ofLength: 2048)
            if let tailContent = String(data: tailData, encoding: .utf8) {
                let tailLines = tailContent.components(separatedBy: "\n")
                for line in tailLines.reversed() {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
                    if let entry = try? decoder.decode(TranscriptEntry.self, from: lineData),
                       entry.type == "last-prompt" {
                        quick.lastPrompt = entry.lastPrompt
                        break
                    }
                }
            }
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

        // Truncate to reasonable length
        if firstLine.count > 100 {
            return String(firstLine.prefix(100)) + "…"
        }
        return firstLine
    }
}
