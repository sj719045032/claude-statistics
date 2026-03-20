import Foundation

enum StatsPeriod: String, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"

    var localizedName: String {
        switch self {
        case .daily: return String(localized: "period.daily")
        case .weekly: return String(localized: "period.weekly")
        case .monthly: return String(localized: "period.monthly")
        case .yearly: return String(localized: "period.yearly")
        }
    }

    func startOfPeriod(for date: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .daily:
            return cal.startOfDay(for: date)
        case .weekly:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return cal.date(from: comps) ?? cal.startOfDay(for: date)
        case .monthly:
            let comps = cal.dateComponents([.year, .month], from: date)
            return cal.date(from: comps) ?? cal.startOfDay(for: date)
        case .yearly:
            let comps = cal.dateComponents([.year], from: date)
            return cal.date(from: comps) ?? cal.startOfDay(for: date)
        }
    }

    func label(for date: Date) -> String {
        let fmt = DateFormatter()
        switch self {
        case .daily:
            fmt.dateFormat = "MM/dd"
        case .weekly:
            fmt.dateFormat = "MM/dd"
            let end = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
            let fmtEnd = DateFormatter()
            fmtEnd.dateFormat = "MM/dd"
            return "\(fmt.string(from: date))~\(fmtEnd.string(from: end))"
        case .monthly:
            fmt.dateFormat = "yyyy/MM"
        case .yearly:
            fmt.dateFormat = "yyyy"
        }
        return fmt.string(from: date)
    }

    var displayCount: Int {
        switch self {
        case .daily: return 7
        case .weekly: return 4
        case .monthly: return 12
        case .yearly: return 10
        }
    }
}

struct PeriodStats: Identifiable {
    let period: Date
    let periodLabel: String
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var cacheCreation5mTokens: Int = 0
    var cacheCreation1hTokens: Int = 0
    var cacheCreationTotalTokens: Int = 0
    var cacheReadTokens: Int = 0
    var totalCost: Double = 0
    var sessionCount: Int = 0
    var messageCount: Int = 0
    var toolUseCount: Int = 0
    var hasEstimatedCost: Bool = false
    var modelBreakdown: [String: ModelUsage] = [:]

    var id: Date { period }

    var totalTokens: Int {
        totalInputTokens + totalOutputTokens + cacheCreationTotalTokens + cacheReadTokens
    }

    mutating func accumulate(stats: SessionStats) {
        totalInputTokens += stats.totalInputTokens
        totalOutputTokens += stats.totalOutputTokens
        cacheCreation5mTokens += stats.cacheCreation5mTokens
        cacheCreation1hTokens += stats.cacheCreation1hTokens
        cacheCreationTotalTokens += stats.cacheCreationTotalTokens
        cacheReadTokens += stats.cacheReadTokens
        totalCost += stats.estimatedCost
        if stats.isCostEstimated { hasEstimatedCost = true }
        sessionCount += 1
        messageCount += stats.messageCount
        toolUseCount += stats.toolUseTotal

        // Accumulate per-model breakdown from session's detailed model data
        if stats.modelBreakdown.isEmpty {
            // Fallback: session has no per-model breakdown, use session-level model
            let model = stats.model
            var usage = modelBreakdown[model] ?? ModelUsage(model: model)
            usage.inputTokens += stats.totalInputTokens
            usage.outputTokens += stats.totalOutputTokens
            usage.cacheCreation5mTokens += stats.cacheCreation5mTokens
            usage.cacheCreation1hTokens += stats.cacheCreation1hTokens
            usage.cacheCreationTotalTokens += stats.cacheCreationTotalTokens
            usage.cacheReadTokens += stats.cacheReadTokens
            usage.cost += stats.estimatedCost
            usage.sessionCount += 1
            if stats.isCostEstimated { usage.isEstimated = true }
            modelBreakdown[model] = usage
        } else {
            // Use precise per-model token data
            for (model, mts) in stats.modelBreakdown {
                var usage = modelBreakdown[model] ?? ModelUsage(model: model)
                usage.inputTokens += mts.inputTokens
                usage.outputTokens += mts.outputTokens
                usage.cacheCreation5mTokens += mts.cacheCreation5mTokens
                usage.cacheCreation1hTokens += mts.cacheCreation1hTokens
                usage.cacheCreationTotalTokens += mts.cacheCreationTotalTokens
                usage.cacheReadTokens += mts.cacheReadTokens
                let cost = ModelPricing.estimateCost(
                    model: model,
                    inputTokens: mts.inputTokens,
                    outputTokens: mts.outputTokens,
                    cacheCreation5mTokens: mts.cacheCreation5mTokens,
                    cacheCreation1hTokens: mts.cacheCreation1hTokens,
                    cacheCreationTotalTokens: mts.cacheCreationTotalTokens,
                    cacheReadTokens: mts.cacheReadTokens
                )
                usage.cost += cost
                usage.sessionCount += 1
                if !ModelPricing.shared.isExactMatch(for: model) {
                    usage.isEstimated = true
                }
                modelBreakdown[model] = usage
            }
        }
    }
}

struct ModelUsage: Identifiable {
    let model: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreation5mTokens: Int = 0
    var cacheCreation1hTokens: Int = 0
    var cacheCreationTotalTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cost: Double = 0
    var sessionCount: Int = 0
    var messageCount: Int = 0
    var isEstimated: Bool = false

    var id: String { model }
    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTotalTokens + cacheReadTokens }
}
