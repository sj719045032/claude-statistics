import Foundation

struct Session: Identifiable, Hashable {
    let id: String
    let externalID: String
    let provider: ProviderKind
    let projectPath: String
    let filePath: String
    let startTime: Date?
    let lastModified: Date
    let fileSize: Int64

    /// Real project directory read from JSONL cwd field
    var cwd: String?

    var displayName: String {
        if let cwd, !cwd.isEmpty {
            return cwd
        }
        // Fallback: show project folder name as-is (can't reliably convert - to /)
        return (projectPath as NSString).lastPathComponent
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(id)
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.provider == rhs.provider && lhs.id == rhs.id
    }
}

struct ModelTokenStats: Codable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreation5mTokens: Int = 0
    var cacheCreation1hTokens: Int = 0
    var cacheCreationTotalTokens: Int = 0
    var cacheReadTokens: Int = 0
    var messageCount: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTotalTokens + cacheReadTokens }

    var estimatedCost: Double {
        0 // computed externally with model name
    }
}

struct SessionStats: Codable {
    // MARK: - Stored: session-level metadata
    var model: String = "Unknown"
    var startTime: Date?
    var endTime: Date?
    var latestProgressNote: String?
    var latestProgressNoteAt: Date?
    var lastPrompt: String?
    var lastPromptAt: Date?
    var lastOutputPreview: String?
    var lastOutputPreviewAt: Date?
    var lastToolName: String?
    var lastToolSummary: String?
    var lastToolDetail: String?
    var lastToolAt: Date?
    var contextTokens: Int = 0          // last message's input context size (input + cache_read)
    var userMessageCount: Int = 0
    var assistantMessageCount: Int = 0

    // MARK: - Stored: single source of truth for time-bucketed data
    /// Per-5-minute token/cost data, keyed by 5-minute boundary in local timezone.
    /// All other aggregations (hour, day, totals, modelBreakdown) are derived from this.
    var fiveMinSlices: [Date: DaySlice] = [:]

    // MARK: - Derived from fiveMinSlices

    var totalInputTokens: Int { fiveMinSlices.values.reduce(0) { $0 + $1.totalInputTokens } }
    var totalOutputTokens: Int { fiveMinSlices.values.reduce(0) { $0 + $1.totalOutputTokens } }
    var cacheCreation5mTokens: Int { fiveMinSlices.values.reduce(0) { $0 + $1.cacheCreation5mTokens } }
    var cacheCreation1hTokens: Int { fiveMinSlices.values.reduce(0) { $0 + $1.cacheCreation1hTokens } }
    var cacheCreationTotalTokens: Int { fiveMinSlices.values.reduce(0) { $0 + $1.cacheCreationTotalTokens } }
    var cacheReadTokens: Int { fiveMinSlices.values.reduce(0) { $0 + $1.cacheReadTokens } }
    var messageCount: Int { fiveMinSlices.values.reduce(0) { $0 + $1.messageCount } }

    var toolUseCounts: [String: Int] {
        var merged: [String: Int] = [:]
        for slice in fiveMinSlices.values {
            for (tool, count) in slice.toolUseCounts {
                merged[tool, default: 0] += count
            }
        }
        return merged
    }

    var modelBreakdown: [String: ModelTokenStats] {
        var merged: [String: ModelTokenStats] = [:]
        for slice in fiveMinSlices.values {
            for (model, mts) in slice.modelBreakdown {
                var existing = merged[model, default: ModelTokenStats()]
                existing.inputTokens += mts.inputTokens
                existing.outputTokens += mts.outputTokens
                existing.cacheCreation5mTokens += mts.cacheCreation5mTokens
                existing.cacheCreation1hTokens += mts.cacheCreation1hTokens
                existing.cacheCreationTotalTokens += mts.cacheCreationTotalTokens
                existing.cacheReadTokens += mts.cacheReadTokens
                existing.messageCount += mts.messageCount
                merged[model] = existing
            }
        }
        return merged
    }

    /// Per-hour data derived from fiveMinSlices, keyed by start of hour.
    var hourSlices: [Date: DaySlice] {
        let cal = Calendar.current
        var buckets: [Date: DaySlice] = [:]
        for (sliceStart, slice) in fiveMinSlices {
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: sliceStart)
            let hourStart = cal.date(from: comps) ?? sliceStart
            buckets[hourStart, default: DaySlice()].merge(slice)
        }
        return buckets
    }

    /// Per-day data derived from fiveMinSlices, keyed by startOfDay in local timezone.
    var daySlices: [Date: DaySlice] {
        let cal = Calendar.current
        var buckets: [Date: DaySlice] = [:]
        for (sliceStart, slice) in fiveMinSlices {
            let dayStart = cal.startOfDay(for: sliceStart)
            buckets[dayStart, default: DaySlice()].merge(slice)
        }
        return buckets
    }

    // MARK: - Convenience computed properties

    var contextWindowSize: Int {
        let m = model.lowercased()
        if m.contains("opus-4-7") || m.contains("opus-4-6") {
            return 1_000_000
        }
        return 200_000
    }

    var contextUsagePercent: Double {
        guard contextWindowSize > 0, contextTokens > 0 else { return 0 }
        return min(100, (Double(contextTokens) / Double(contextWindowSize) * 100).rounded())
    }

    var totalTokens: Int { totalInputTokens + totalOutputTokens + cacheCreationTotalTokens + cacheReadTokens }

    var sortedModelBreakdown: [(model: String, stats: ModelTokenStats)] {
        modelBreakdown.sorted { $0.value.totalTokens > $1.value.totalTokens }
            .map { (model: $0.key, stats: $0.value) }
    }

    var asModelUsages: [ModelUsage] {
        if modelBreakdown.isEmpty {
            var u = ModelUsage(model: model)
            u.inputTokens = totalInputTokens
            u.outputTokens = totalOutputTokens
            u.cacheCreation5mTokens = cacheCreation5mTokens
            u.cacheCreation1hTokens = cacheCreation1hTokens
            u.cacheCreationTotalTokens = cacheCreationTotalTokens
            u.cacheReadTokens = cacheReadTokens
            u.cost = estimatedCost
            u.sessionCount = 1
            u.isEstimated = isCostEstimated
            return [u]
        }
        return modelBreakdown.map { (key, mts) in
            var u = ModelUsage(model: key)
            u.inputTokens = mts.inputTokens
            u.outputTokens = mts.outputTokens
            u.cacheCreation5mTokens = mts.cacheCreation5mTokens
            u.cacheCreation1hTokens = mts.cacheCreation1hTokens
            u.cacheCreationTotalTokens = mts.cacheCreationTotalTokens
            u.cacheReadTokens = mts.cacheReadTokens
            u.messageCount = mts.messageCount
            u.cost = ModelPricing.estimateCost(
                model: key,
                inputTokens: mts.inputTokens,
                outputTokens: mts.outputTokens,
                cacheCreation5mTokens: mts.cacheCreation5mTokens,
                cacheCreation1hTokens: mts.cacheCreation1hTokens,
                cacheCreationTotalTokens: mts.cacheCreationTotalTokens,
                cacheReadTokens: mts.cacheReadTokens
            )
            u.sessionCount = 1
            u.isEstimated = !ModelPricing.shared.isExactMatch(for: key)
            return u
        }.sorted { $0.totalTokens > $1.totalTokens }
    }

    var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }

    var toolUseTotal: Int {
        toolUseCounts.values.reduce(0, +)
    }

    // MARK: - Codable (only stored fields)
    enum CodingKeys: String, CodingKey {
        case model, startTime, endTime, latestProgressNote, latestProgressNoteAt
        case lastPrompt, lastPromptAt, lastOutputPreview, lastOutputPreviewAt
        case lastToolName, lastToolSummary, lastToolDetail, lastToolAt, contextTokens
        case userMessageCount, assistantMessageCount, fiveMinSlices
    }

    func encode(to encoder: Encoder) throws {
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

    init(from decoder: Decoder) throws {
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
    }

    init() {}

    struct DaySlice: Codable {
        var totalInputTokens: Int = 0
        var totalOutputTokens: Int = 0
        var cacheCreation5mTokens: Int = 0
        var cacheCreation1hTokens: Int = 0
        var cacheCreationTotalTokens: Int = 0
        var cacheReadTokens: Int = 0
        var messageCount: Int = 0
        var toolUseCounts: [String: Int] = [:]
        var modelBreakdown: [String: ModelTokenStats] = [:]

        var toolUseTotal: Int { toolUseCounts.values.reduce(0, +) }
        var totalTokens: Int { totalInputTokens + totalOutputTokens + cacheCreationTotalTokens + cacheReadTokens }

        var estimatedCost: Double {
            modelBreakdown.reduce(0.0) { total, entry in
                total + ModelPricing.estimateCost(
                    model: entry.key,
                    inputTokens: entry.value.inputTokens,
                    outputTokens: entry.value.outputTokens,
                    cacheCreation5mTokens: entry.value.cacheCreation5mTokens,
                    cacheCreation1hTokens: entry.value.cacheCreation1hTokens,
                    cacheCreationTotalTokens: entry.value.cacheCreationTotalTokens,
                    cacheReadTokens: entry.value.cacheReadTokens
                )
            }
        }

        var isCostEstimated: Bool {
            modelBreakdown.keys.contains { !ModelPricing.shared.isExactMatch(for: $0) }
        }

        mutating func merge(_ other: DaySlice) {
            totalInputTokens += other.totalInputTokens
            totalOutputTokens += other.totalOutputTokens
            cacheCreation5mTokens += other.cacheCreation5mTokens
            cacheCreation1hTokens += other.cacheCreation1hTokens
            cacheCreationTotalTokens += other.cacheCreationTotalTokens
            cacheReadTokens += other.cacheReadTokens
            messageCount += other.messageCount
            for (tool, count) in other.toolUseCounts {
                toolUseCounts[tool, default: 0] += count
            }
            for (model, mts) in other.modelBreakdown {
                var existing = modelBreakdown[model, default: ModelTokenStats()]
                existing.inputTokens += mts.inputTokens
                existing.outputTokens += mts.outputTokens
                existing.cacheCreation5mTokens += mts.cacheCreation5mTokens
                existing.cacheCreation1hTokens += mts.cacheCreation1hTokens
                existing.cacheCreationTotalTokens += mts.cacheCreationTotalTokens
                existing.cacheReadTokens += mts.cacheReadTokens
                existing.messageCount += mts.messageCount
                modelBreakdown[model] = existing
            }
        }
    }

    var sortedToolUses: [(name: String, count: Int)] {
        toolUseCounts.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }

    /// Whether the cost is an estimate (no exact pricing for this model)
    var isCostEstimated: Bool {
        !ModelPricing.shared.isExactMatch(for: model)
    }

    /// Estimated cost in USD based on model pricing
    var estimatedCost: Double {
        // If we have per-model breakdown, sum each model's cost accurately
        if !modelBreakdown.isEmpty {
            return modelBreakdown.reduce(0.0) { total, entry in
                total + ModelPricing.estimateCost(
                    model: entry.key,
                    inputTokens: entry.value.inputTokens,
                    outputTokens: entry.value.outputTokens,
                    cacheCreation5mTokens: entry.value.cacheCreation5mTokens,
                    cacheCreation1hTokens: entry.value.cacheCreation1hTokens,
                    cacheCreationTotalTokens: entry.value.cacheCreationTotalTokens,
                    cacheReadTokens: entry.value.cacheReadTokens
                )
            }
        }
        // Fallback: no breakdown, use session-level model
        return ModelPricing.estimateCost(
            model: model,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            cacheCreation5mTokens: cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens,
            cacheCreationTotalTokens: cacheCreationTotalTokens,
            cacheReadTokens: cacheReadTokens
        )
    }
}

/// Model pricing (per million tokens, USD)
/// Pricing is loaded from a local JSON config file (~/.claude-statistics/pricing.json).
/// Built-in defaults cover Claude and known OpenAI/Codex models, then user config overrides them.
final class ModelPricing {
    static let shared = ModelPricing()

    struct Pricing: Codable {
        let input: Double
        let output: Double
        let cacheWrite5m: Double    // 5-min cache write (1.25x base input)
        let cacheWrite1h: Double    // 1-hour cache write (2x base input)
        let cacheRead: Double       // cache hit (0.1x base input)

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheWrite5m = "cache_write_5m"
            case cacheWrite1h = "cache_write_1h"
            case cacheRead = "cache_read"
        }
    }

    private(set) var models: [String: Pricing] = [:]
    private(set) var defaultPricing = Pricing(input: 3.0, output: 15.0, cacheWrite5m: 3.75, cacheWrite1h: 6.0, cacheRead: 0.30)

    private static var builtinModels: [String: Pricing] {
        ProviderRegistry.supportedProviders.reduce(into: [:]) { merged, kind in
            let provider = ProviderRegistry.provider(for: kind)
            merged.merge(provider.builtinPricingModels) { current, _ in current }
        }
    }

    private var configDir: String {
        AppRuntimePaths.rootDirectory
    }

    private var pricingFilePath: String {
        (configDir as NSString).appendingPathComponent("pricing.json")
    }

    init() {
        loadPricing()
    }

    private func loadPricing() {
        let fm = FileManager.default

        // Try loading from config file
        if let data = fm.contents(atPath: pricingFilePath),
           let loaded = try? JSONDecoder().decode(PricingFile.self, from: data) {
            var merged = Self.builtinModels
            merged.merge(loaded.models) { _, user in user }
            models = merged
            if let d = loaded.default_pricing { defaultPricing = d }
            return
        }

        // Use built-in defaults and write config file for user to edit
        models = Self.builtinModels
        savePricing()
    }

    /// Merge remotely fetched pricing into the current model set and persist
    func updateModels(_ newModels: [String: Pricing]) {
        models.merge(newModels) { _, fetched in fetched }
        savePricing()
    }

    /// Update a single model's pricing and persist
    func updateModel(id: String, pricing: Pricing) {
        models[id] = pricing
        savePricing()
    }

    /// Remove a model and persist
    func removeModel(id: String) {
        models.removeValue(forKey: id)
        savePricing()
    }

    /// Reload pricing from disk
    func reload() {
        loadPricing()
    }

    private func savePricing() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }

        let file = PricingFile(
            _comment: "Model pricing per million tokens (USD). Edit this file to update pricing. App reads on launch.",
            models: models,
            default_pricing: defaultPricing
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            try? data.write(to: URL(fileURLWithPath: pricingFilePath))
        }
    }

    /// Whether we have an exact pricing match for the model
    func isExactMatch(for model: String) -> Bool {
        models[model] != nil
    }

    func pricing(for model: String) -> Pricing {
        if let p = models[model] { return p }
        let lower = model.lowercased()
        if lower.contains("gemini-3.1-pro") { return models["gemini-3.1-pro-preview"] ?? defaultPricing }
        if lower.contains("gemini-3-pro") { return models["gemini-3-pro-preview"] ?? defaultPricing }
        if lower.contains("gemini-3.1-flash-lite") { return models["gemini-3.1-flash-lite-preview"] ?? defaultPricing }
        if lower.contains("gemini-3-flash") { return models["gemini-3-flash-preview"] ?? defaultPricing }
        if lower.contains("gpt-5.4-mini") { return models["gpt-5.4-mini"] ?? defaultPricing }
        if lower.contains("gpt-5.4") { return models["gpt-5.4"] ?? defaultPricing }
        if lower.contains("gpt-5.3-codex") { return models["gpt-5.3-codex"] ?? defaultPricing }
        if lower.contains("gpt-5.2-codex") { return models["gpt-5.2-codex"] ?? defaultPricing }
        if lower.contains("gpt-5.1-codex-mini") { return models["gpt-5.1-codex-mini"] ?? defaultPricing }
        if lower.contains("gpt-5.1-codex-max") { return models["gpt-5.1-codex-max"] ?? defaultPricing }
        if lower.contains("gpt-5.1-codex") { return models["gpt-5.1-codex"] ?? defaultPricing }
        if lower.contains("gpt-5-codex") { return models["gpt-5-codex"] ?? defaultPricing }
        if lower.contains("gpt-5.1") { return models["gpt-5.1"] ?? defaultPricing }
        if lower.contains("gpt-5") { return models["gpt-5"] ?? defaultPricing }
        if lower.contains("gemini") {
            if lower.contains("flash-lite") { return models["gemini-2.5-flash-lite"] ?? defaultPricing }
            if lower.contains("flash") { return models["gemini-2.5-flash"] ?? defaultPricing }
            if lower.contains("pro") { return models["gemini-2.5-pro"] ?? defaultPricing }
        }
        if lower.contains("opus-4-7") { return models["claude-opus-4-7"] ?? defaultPricing }
        if lower.contains("opus-4-6") { return models["claude-opus-4-6"] ?? defaultPricing }
        if lower.contains("opus-4-5") { return models["claude-opus-4-5-20251101"] ?? defaultPricing }
        if lower.contains("opus-4-1") { return models["claude-opus-4-1-20250805"] ?? defaultPricing }
        if lower.contains("opus-4") { return models["claude-opus-4-20250514"] ?? defaultPricing }
        if lower.contains("opus") { return models.first { $0.key.contains("opus") }?.value ?? defaultPricing }
        if lower.contains("haiku") { return models.first { $0.key.contains("haiku") }?.value ?? defaultPricing }
        if lower.contains("sonnet") { return models.first { $0.key.contains("sonnet") }?.value ?? defaultPricing }
        return defaultPricing
    }

    // Keep static convenience methods for compatibility
    static func pricing(for model: String) -> Pricing {
        shared.pricing(for: model)
    }

    static func estimateCost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreation5mTokens: Int,
        cacheCreation1hTokens: Int,
        cacheCreationTotalTokens: Int,
        cacheReadTokens: Int
    ) -> Double {
        let p = shared.pricing(for: model)
        let perM = 1_000_000.0

        var cost = Double(inputTokens) / perM * p.input
            + Double(outputTokens) / perM * p.output
            + Double(cacheReadTokens) / perM * p.cacheRead

        // If we have the 5m/1h breakdown, use precise rates
        if cacheCreation5mTokens > 0 || cacheCreation1hTokens > 0 {
            cost += Double(cacheCreation5mTokens) / perM * p.cacheWrite5m
            cost += Double(cacheCreation1hTokens) / perM * p.cacheWrite1h
        } else if cacheCreationTotalTokens > 0 {
            // Fallback: no breakdown available, assume 1h rate (conservative)
            cost += Double(cacheCreationTotalTokens) / perM * p.cacheWrite1h
        }

        return cost
    }
}

private struct PricingFile: Codable {
    let _comment: String?
    let models: [String: ModelPricing.Pricing]
    let default_pricing: ModelPricing.Pricing?
}
