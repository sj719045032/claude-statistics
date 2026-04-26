import SwiftUI

func detailFormatCost(_ cost: Double) -> String {
    if cost >= 1.0 { return String(format: "$%.2f", cost) }
    if cost >= 0.01 { return String(format: "$%.3f", cost) }
    return String(format: "$%.4f", cost)
}

func detailCostColor(_ cost: Double) -> Color {
    if cost > 1.0 { return .red }
    if cost > 0.1 { return .orange }
    return .green
}

func detailDisplayModel(_ model: String) -> String {
    model.replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "-20", with: " (20")
        .appending(model.contains("-20") ? ")" : "")
}
