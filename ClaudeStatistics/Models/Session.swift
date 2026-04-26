import Foundation
import ClaudeStatisticsKit

// `Session` lives in `ClaudeStatisticsKit` (SDK). Host code keeps only the
// host-side helpers below that depend on the still-host-side `ProviderKind`.

extension Session {
    /// Best-effort mapping back to the legacy `ProviderKind` enum for code
    /// paths that still depend on host-side branching. Returns `nil` when
    /// `provider` is a third-party plugin id outside the builtin trio.
    var providerKind: ProviderKind? {
        ProviderKind(rawValue: provider)
    }
}

// ModelTokenStats lives in ClaudeStatisticsKit.

// SessionStats lives in ClaudeStatisticsKit (top-level Codable struct).
// Host-side cost helpers (estimatedCost / isCostEstimated /
// asModelUsages) are attached via SessionStats+Pricing.swift.

/// Model pricing (per million tokens, USD)
/// Pricing is loaded from a local JSON config file (~/.claude-statistics/pricing.json).
/// Built-in defaults cover Claude and known OpenAI/Codex models, then user config overrides them.
final class ModelPricing {
    static let shared = ModelPricing()

    /// Legacy alias — the rate struct now lives in `ClaudeStatisticsKit`
    /// as `ModelPricingRates` so plugins emit it directly. Existing host
    /// call sites of the form `ModelPricing.Pricing(...)` keep working
    /// via this typealias.
    typealias Pricing = ModelPricingRates

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
