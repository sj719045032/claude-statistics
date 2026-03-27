import Foundation

struct Session: Identifiable, Hashable {
    let id: String
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
        hasher.combine(id)
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}

struct ModelTokenStats {
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

struct SessionStats {
    var model: String = "Unknown"
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var cacheCreation5mTokens: Int = 0   // 5-min cache write (1.25x)
    var cacheCreation1hTokens: Int = 0   // 1-hour cache write (2x)
    var cacheCreationTotalTokens: Int = 0 // total cache_creation_input_tokens (fallback)
    var cacheReadTokens: Int = 0          // cache hit (0.1x)
    var messageCount: Int = 0
    var userMessageCount: Int = 0
    var assistantMessageCount: Int = 0
    var toolUseCounts: [String: Int] = [:]
    var startTime: Date?
    var endTime: Date?
    var lastPrompt: String?
    var contextTokens: Int = 0          // last message's input context size (input + cache_read)
    var modelBreakdown: [String: ModelTokenStats] = [:]

    /// Context window size for the primary model
    var contextWindowSize: Int {
        let m = model.lowercased()
        // Claude Code uses extended thinking with 1M context for latest models
        if m.contains("opus-4-6") || m.contains("sonnet-4-6") || m.contains("opus-4-5") || m.contains("sonnet-4-5") {
            return 1_000_000
        }
        // Older models or haiku use 200K
        return 200_000
    }

    /// Context usage percentage (0-100), rounded to match Claude Code's Math.round()
    var contextUsagePercent: Double {
        guard contextWindowSize > 0, contextTokens > 0 else { return 0 }
        return min(100, (Double(contextTokens) / Double(contextWindowSize) * 100).rounded())
    }

    var totalTokens: Int { totalInputTokens + totalOutputTokens + cacheCreationTotalTokens + cacheReadTokens }

    var sortedModelBreakdown: [(model: String, stats: ModelTokenStats)] {
        modelBreakdown.sorted { $0.value.totalTokens > $1.value.totalTokens }
            .map { (model: $0.key, stats: $0.value) }
    }

    /// Converts per-model token data to [ModelUsage] for use with CostModelsCard
    var asModelUsages: [ModelUsage] {
        if modelBreakdown.isEmpty {
            // Single-model fallback
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

    // MARK: - Per-day breakdown (for accurate daily statistics)

    /// Per-day token/cost data, keyed by startOfDay in local timezone.
    /// Sessions spanning multiple days have tokens attributed to each day.
    var daySlices: [Date: DaySlice] = [:]

    struct DaySlice {
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

/// Claude model pricing (per million tokens, USD)
/// Pricing is loaded from a local JSON config file (~/.claude-statistics/pricing.json).
/// If the file doesn't exist, built-in defaults are used and written to the file for easy editing.
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

    // Source: https://docs.anthropic.com/en/docs/about-claude/pricing (2026-03-20)
    // cache_write_5m = 1.25x base input,  cache_write_1h = 2x base input,  cache_read = 0.1x base input
    private static let builtinModels: [String: Pricing] = [
        // Opus 4.6 / 4.5 — $5 in, $25 out
        "claude-opus-4-6":              Pricing(input: 5.0,  output: 25.0, cacheWrite5m: 6.25,  cacheWrite1h: 10.0,  cacheRead: 0.50),
        "claude-opus-4-5-20251101":     Pricing(input: 5.0,  output: 25.0, cacheWrite5m: 6.25,  cacheWrite1h: 10.0,  cacheRead: 0.50),
        // Opus 4.1 / 4 — $15 in, $75 out
        "claude-opus-4-1-20250805":     Pricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0,  cacheRead: 1.50),
        "claude-opus-4-20250514":       Pricing(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0,  cacheRead: 1.50),
        // Sonnet 4.6 / 4.5 / 4 — $3 in, $15 out
        "claude-sonnet-4-6":            Pricing(input: 3.0,  output: 15.0, cacheWrite5m: 3.75,  cacheWrite1h: 6.0,   cacheRead: 0.30),
        "claude-sonnet-4-5-20250929":   Pricing(input: 3.0,  output: 15.0, cacheWrite5m: 3.75,  cacheWrite1h: 6.0,   cacheRead: 0.30),
        "claude-sonnet-4-20250514":     Pricing(input: 3.0,  output: 15.0, cacheWrite5m: 3.75,  cacheWrite1h: 6.0,   cacheRead: 0.30),
        // Haiku 4.5 — $1 in, $5 out
        "claude-haiku-4-5-20251001":    Pricing(input: 1.0,  output: 5.0,  cacheWrite5m: 1.25,  cacheWrite1h: 2.0,   cacheRead: 0.10),
        // Haiku 3.5 — $0.80 in, $4 out
        "claude-3-5-haiku-20241022":    Pricing(input: 0.80, output: 4.0,  cacheWrite5m: 1.0,   cacheWrite1h: 1.60,  cacheRead: 0.08),
        // Haiku 3 — $0.25 in, $1.25 out
        "claude-3-haiku-20240307":      Pricing(input: 0.25, output: 1.25, cacheWrite5m: 0.3125, cacheWrite1h: 0.50, cacheRead: 0.025),
    ]

    private var configDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude-statistics")
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
            models = loaded.models
            if let d = loaded.default_pricing { defaultPricing = d }
            return
        }

        // Use built-in defaults and write config file for user to edit
        models = Self.builtinModels
        savePricing()
    }

    /// Replace all pricing with remotely fetched data and persist
    func updateModels(_ newModels: [String: Pricing]) {
        models = newModels
        savePricing()
    }

    /// Update a single model's pricing and persist
    func updateModel(id: String, pricing: Pricing) {
        models[id] = pricing
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
