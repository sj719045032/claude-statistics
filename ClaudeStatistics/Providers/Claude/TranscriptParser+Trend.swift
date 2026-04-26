import Foundation
import ClaudeStatisticsKit

extension TranscriptParser {
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
}
