import Foundation

/// Full per-session aggregate emitted by a plugin's transcript parser.
/// `fiveMinSlices` is the single source of truth — every coarser
/// aggregation (hour, day, totals, model breakdown) is derived from
/// it, and `Codable` only persists the stored fields. Cost-estimation
/// helpers (`estimatedCost`, `isCostEstimated`) and the per-model
/// `ModelUsage` projection live in a host-side extension because
/// they need the host's pricing table.
public struct SessionStats: Codable, Sendable {
    // MARK: - Stored: session-level metadata
    public var model: String
    public var startTime: Date?
    public var endTime: Date?
    public var latestProgressNote: String?
    public var latestProgressNoteAt: Date?
    public var lastPrompt: String?
    public var lastPromptAt: Date?
    public var lastOutputPreview: String?
    public var lastOutputPreviewAt: Date?
    public var lastToolName: String?
    public var lastToolSummary: String?
    public var lastToolDetail: String?
    public var lastToolAt: Date?
    /// Last message's input context size (input + cache_read).
    public var contextTokens: Int
    public var userMessageCount: Int
    public var assistantMessageCount: Int

    // MARK: - Stored: single source of truth for time-bucketed data
    /// Per-5-minute token / cost data, keyed by 5-minute boundary in
    /// local timezone. All other aggregations (hour, day, totals,
    /// modelBreakdown) are derived from this.
    public var fiveMinSlices: [Date: DaySlice]

    // MARK: - Stored aggregates (precomputed)
    //
    // These were O(slices) computed properties — re-walked `fiveMinSlices`
    // on every access. SwiftUI views like `StatisticsView` and
    // `AllTimeView` read several of them per render per session, which
    // dominated CPU when many sessions were loaded. Now they are stored
    // and populated once by `precomputeAggregates()` (called at the end
    // of every `parseSession` and the end of `init(from:)`). They are
    // **not** part of `Codable` — derived purely from `fiveMinSlices`,
    // so we recompute on decode rather than bloat `stats_json`.
    //
    // Mutators of `fiveMinSlices` MUST call `precomputeAggregates()`
    // before publishing the value. The provided `init()` /
    // `init(from:)` already do this; parsers call it at the end of
    // `parseSession`.

    public private(set) var totalInputTokens: Int = 0
    public private(set) var totalOutputTokens: Int = 0
    public private(set) var cacheCreation5mTokens: Int = 0
    public private(set) var cacheCreation1hTokens: Int = 0
    public private(set) var cacheCreationTotalTokens: Int = 0
    public private(set) var cacheReadTokens: Int = 0
    public private(set) var messageCount: Int = 0
    public private(set) var toolUseCounts: [String: Int] = [:]
    public private(set) var modelBreakdown: [String: ModelTokenStats] = [:]

    /// Recompute every stored aggregate above from `fiveMinSlices`. Call
    /// this once after finishing a parse or after decoding from cache.
    /// O(N) over total slice count — same single pass as the old
    /// computed-property walks, but only happens once per parse instead
    /// of per-View-render.
    public mutating func precomputeAggregates() {
        var totalInput = 0
        var totalOutput = 0
        var cache5m = 0
        var cache1h = 0
        var cacheTotal = 0
        var cacheRead = 0
        var messages = 0
        var tools: [String: Int] = [:]
        var models: [String: ModelTokenStats] = [:]

        for slice in fiveMinSlices.values {
            totalInput += slice.totalInputTokens
            totalOutput += slice.totalOutputTokens
            cache5m += slice.cacheCreation5mTokens
            cache1h += slice.cacheCreation1hTokens
            cacheTotal += slice.cacheCreationTotalTokens
            cacheRead += slice.cacheReadTokens
            messages += slice.messageCount
            for (tool, count) in slice.toolUseCounts {
                tools[tool, default: 0] += count
            }
            for (model, mts) in slice.modelBreakdown {
                var existing = models[model, default: ModelTokenStats()]
                existing.inputTokens += mts.inputTokens
                existing.outputTokens += mts.outputTokens
                existing.cacheCreation5mTokens += mts.cacheCreation5mTokens
                existing.cacheCreation1hTokens += mts.cacheCreation1hTokens
                existing.cacheCreationTotalTokens += mts.cacheCreationTotalTokens
                existing.cacheReadTokens += mts.cacheReadTokens
                existing.messageCount += mts.messageCount
                models[model] = existing
            }
        }

        self.totalInputTokens = totalInput
        self.totalOutputTokens = totalOutput
        self.cacheCreation5mTokens = cache5m
        self.cacheCreation1hTokens = cache1h
        self.cacheCreationTotalTokens = cacheTotal
        self.cacheReadTokens = cacheRead
        self.messageCount = messages
        self.toolUseCounts = tools
        self.modelBreakdown = models
    }

    /// Per-hour buckets, keyed by the start of each hour.
    public var hourSlices: [Date: DaySlice] {
        let cal = Calendar.current
        var buckets: [Date: DaySlice] = [:]
        for (sliceStart, slice) in fiveMinSlices {
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: sliceStart)
            let hourStart = cal.date(from: comps) ?? sliceStart
            buckets[hourStart, default: DaySlice()].merge(slice)
        }
        return buckets
    }

    /// Per-day buckets, keyed by `startOfDay` in the local timezone.
    public var daySlices: [Date: DaySlice] {
        let cal = Calendar.current
        var buckets: [Date: DaySlice] = [:]
        for (sliceStart, slice) in fiveMinSlices {
            let dayStart = cal.startOfDay(for: sliceStart)
            buckets[dayStart, default: DaySlice()].merge(slice)
        }
        return buckets
    }

    // MARK: - Convenience computed properties

    /// Heuristic context-window size for the recorded model. Plugins
    /// can override the default by emitting their own statistics from
    /// API metadata once stage-4 lifts the per-model lookup into a
    /// `ProviderPlugin` factory.
    public var contextWindowSize: Int {
        let m = model.lowercased()
        if m.contains("opus-4-7") || m.contains("opus-4-6") {
            return 1_000_000
        }
        return 200_000
    }

    public var contextUsagePercent: Double {
        guard contextWindowSize > 0, contextTokens > 0 else { return 0 }
        return min(100, (Double(contextTokens) / Double(contextWindowSize) * 100).rounded())
    }

    public var totalTokens: Int {
        totalInputTokens + totalOutputTokens + cacheCreationTotalTokens + cacheReadTokens
    }

    public var sortedModelBreakdown: [(model: String, stats: ModelTokenStats)] {
        modelBreakdown
            .sorted { $0.value.totalTokens > $1.value.totalTokens }
            .map { (model: $0.key, stats: $0.value) }
    }

    public var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }

    public var toolUseTotal: Int { toolUseCounts.values.reduce(0, +) }

    public var sortedToolUses: [(name: String, count: Int)] {
        toolUseCounts.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }

    public init() {
        self.model = "Unknown"
        self.contextTokens = 0
        self.userMessageCount = 0
        self.assistantMessageCount = 0
        self.fiveMinSlices = [:]
    }

    // MARK: - Codable (only stored fields)

    private enum CodingKeys: String, CodingKey {
        case model, startTime, endTime, latestProgressNote, latestProgressNoteAt
        case lastPrompt, lastPromptAt, lastOutputPreview, lastOutputPreviewAt
        case lastToolName, lastToolSummary, lastToolDetail, lastToolAt, contextTokens
        case userMessageCount, assistantMessageCount, fiveMinSlices
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(latestProgressNote, forKey: .latestProgressNote)
        try container.encodeIfPresent(latestProgressNoteAt, forKey: .latestProgressNoteAt)
        try container.encodeIfPresent(lastPrompt, forKey: .lastPrompt)
        try container.encodeIfPresent(lastPromptAt, forKey: .lastPromptAt)
        try container.encodeIfPresent(lastOutputPreview, forKey: .lastOutputPreview)
        try container.encodeIfPresent(lastOutputPreviewAt, forKey: .lastOutputPreviewAt)
        try container.encodeIfPresent(lastToolName, forKey: .lastToolName)
        try container.encodeIfPresent(lastToolSummary, forKey: .lastToolSummary)
        try container.encodeIfPresent(lastToolDetail, forKey: .lastToolDetail)
        try container.encodeIfPresent(lastToolAt, forKey: .lastToolAt)
        try container.encode(contextTokens, forKey: .contextTokens)
        try container.encode(userMessageCount, forKey: .userMessageCount)
        try container.encode(assistantMessageCount, forKey: .assistantMessageCount)
        let sliceStringKeyed = Dictionary(uniqueKeysWithValues:
            fiveMinSlices.map { (String($0.key.timeIntervalSince1970), $0.value) }
        )
        try container.encode(sliceStringKeyed, forKey: .fiveMinSlices)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "Unknown"
        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        latestProgressNote = try container.decodeIfPresent(String.self, forKey: .latestProgressNote)
        latestProgressNoteAt = try container.decodeIfPresent(Date.self, forKey: .latestProgressNoteAt)
        lastPrompt = try container.decodeIfPresent(String.self, forKey: .lastPrompt)
        lastPromptAt = try container.decodeIfPresent(Date.self, forKey: .lastPromptAt)
        lastOutputPreview = try container.decodeIfPresent(String.self, forKey: .lastOutputPreview)
        lastOutputPreviewAt = try container.decodeIfPresent(Date.self, forKey: .lastOutputPreviewAt)
        lastToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        lastToolSummary = try container.decodeIfPresent(String.self, forKey: .lastToolSummary)
        lastToolDetail = try container.decodeIfPresent(String.self, forKey: .lastToolDetail)
        lastToolAt = try container.decodeIfPresent(Date.self, forKey: .lastToolAt)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens) ?? 0
        userMessageCount = try container.decodeIfPresent(Int.self, forKey: .userMessageCount) ?? 0
        assistantMessageCount = try container.decodeIfPresent(Int.self, forKey: .assistantMessageCount) ?? 0
        let sliceStringKeyed = try container.decodeIfPresent([String: DaySlice].self, forKey: .fiveMinSlices) ?? [:]
        fiveMinSlices = Dictionary(uniqueKeysWithValues:
            sliceStringKeyed.compactMap { key, value -> (Date, DaySlice)? in
                guard let ti = Double(key) else { return nil }
                return (Date(timeIntervalSince1970: ti), value)
            }
        )
        precomputeAggregates()
    }
}
